import AVFoundation
import Observation

/// 录语音：按住麦克风开始，松开发送，左滑取消。录成 AAC（m4a），QQ 的 silk 由 NapCat 转。最长 60 秒（QQ 的上限）。
@MainActor
@Observable
final class VoiceRecorder {
  private static weak var current: VoiceRecorder?
  static var isBusy: Bool { current?.recording == true || current?.startID != nil }
  static let maxDuration: TimeInterval = 60
  private(set) var recording = false
  private(set) var elapsed: TimeInterval = 0
  /// 最近的音量（0…1），录音条画波形用。
  private(set) var levels: [CGFloat] = []
  /// 手指已经左滑到取消区。
  var willCancel = false
  /// 录到上限自动结束时调用。
  var onAutoFinish: (() -> Void)?
  private var recorder: AVAudioRecorder?
  private var timer: Timer?
  private var startID: UUID?
  @ObservationIgnored private let requestPermission: @MainActor () async -> Bool

  init(requestPermission: @escaping @MainActor () async -> Bool = {
    await AVAudioApplication.requestRecordPermission()
  }) {
    self.requestPermission = requestPermission
  }

  enum StartError: Error { case denied, unavailable }

  #if DEBUG
  /// 调试：没有麦克风的机器（模拟器跑在没麦克风的 Mac 上）用假的音量走一遍录音条。QQB_FAKE_MIC=1 时启用。
  private var fake: Date?
  private static let fakeMic = ["1", "hold"].contains(ProcessInfo.processInfo.environment["QQB_FAKE_MIC"])
  /// QQB_FAKE_MIC=hold：进入聊天页就开始假录音，不松手（截图看录音条用）。
  static let holdFakeRecording = ProcessInfo.processInfo.environment["QQB_FAKE_MIC"] == "hold"
  #endif

  /// 开始录音。没有麦克风权限 / 录不了（例如没有麦克风）时抛错。
  func start() async throws(StartError) {
    guard !recording, startID == nil, !Task.isCancelled else { return }
    guard Self.current == nil || Self.current === self else { throw .unavailable }
    Self.current = self
    let requestID = UUID()
    startID = requestID
    willCancel = false
    defer {
      if startID == requestID { startID = nil }
      if !recording, startID == nil, Self.current === self { Self.current = nil }
    }

    #if DEBUG
    if Self.fakeMic {
      fake = Date()
      recording = true
      willCancel = false
      elapsed = 0
      levels = []
      timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let fake = self.fake else { return }
          self.elapsed = Date().timeIntervalSince(fake)
          self.levels.append(CGFloat(0.2 + 0.7 * abs(sin(self.elapsed * 5)) * Double.random(in: 0.5...1)))
          if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
        }
      }
      return
    }
    #endif
    let allowed = await requestPermission()
    // 授权弹窗期间可能已经松手、离开页面或发起下一次录音；迟到的结果不能复活旧操作。
    guard startID == requestID, !Task.isCancelled else { return }
    guard allowed else { throw .denied }
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
    let activated = (try? audio.setActive(true)) != nil
    // 激活成功而录音器创建/启动失败时，也要归还音频会话，避免其他播放一直被压低。
    defer {
      if activated, !recording { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
    defer { if !recording { try? FileManager.default.removeItem(at: url) } }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 24_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
    guard let r = try? AVAudioRecorder(url: url, settings: settings) else { throw .unavailable }
    r.isMeteringEnabled = true
    guard r.record() else { throw .unavailable }
    recorder = r
    recording = true
    elapsed = 0
    levels = []
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func tick() {
    guard let r = recorder else { return }
    r.updateMeters()
    let db = r.averagePower(forChannel: 0)  // -160…0 dB，人声大多在 -50 以上
    levels.append(CGFloat(max(0, min(1, (db + 50) / 50))))
    if levels.count > 120 { levels.removeFirst(levels.count - 120) }
    elapsed = r.currentTime
    if elapsed >= Self.maxDuration { onAutoFinish?() }
  }

  /// 结束并返回录好的文件和时长；太短（不到 1 秒）返回 nil。
  func finish() -> (url: URL, duration: TimeInterval)? {
    startID = nil
    defer { if !recording, Self.current === self { Self.current = nil } }
    #if DEBUG
    if fake != nil { fake = nil; reset(); return nil }  // 假录音不发送
    #endif
    guard let r = recorder else { return nil }
    let duration = r.currentTime
    r.stop()
    reset()
    guard duration >= 1 else {
      try? FileManager.default.removeItem(at: r.url)
      return nil
    }
    return (r.url, duration)
  }

  func cancel() {
    startID = nil
    defer { if !recording, Self.current === self { Self.current = nil } }
    willCancel = false
    #if DEBUG
    if fake != nil { fake = nil; reset(); return }
    #endif
    guard let r = recorder else { return }
    r.stop()
    r.deleteRecording()
    reset()
  }

  private func reset() {
    timer?.invalidate()
    timer = nil
    recorder = nil
    recording = false
    if Self.current === self { Self.current = nil }
    willCancel = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
