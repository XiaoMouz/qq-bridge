import AVFoundation
import Observation
import QQBridgeProto

@MainActor @Observable
final class AiVoicePreview {
  private static weak var current: AiVoicePreview?
  static func stopCurrent() { current?.stop() }
  private(set) var previewing: String?
  private(set) var error: String?
  private(set) var player: AVPlayer?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private let makePlayer: (URL) -> AVPlayer
  @ObservationIgnored private let startPlayback: (AVPlayer) -> Void
  @ObservationIgnored private let configureAudio: () throws -> Void

  init(makePlayer: @escaping (URL) -> AVPlayer = { AVPlayer(url: $0) },
       startPlayback: @escaping (AVPlayer) -> Void = { $0.play() },
       configureAudio: @escaping () throws -> Void = { try AVAudioSession.sharedInstance().setCategory(.playback) }) {
    self.makePlayer = makePlayer; self.startPlayback = startPlayback; self.configureAudio = configureAudio
  }
  isolated deinit {
    player?.pause()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  func toggle(_ voice: Qqbridge_V1_AiVoice) {
    if previewing == voice.id { stop(); return }
    stop()
    guard let url = URL(string: voice.previewURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
      error = "试听链接不可用"; return
    }
    // 试听与聊天语音共用音频输出，切换入口时先结束旧播放（含仍在等待下载的任务）。
    VoicePlayer.stopCurrent()
    Self.current?.stop(); Self.current = self
    do { try configureAudio() }
    catch { self.error = "无法开始试听：\(error.localizedDescription)"; return }
    let current = makePlayer(url)
    guard let item = current.currentItem else { error = "试听内容不可用"; return }
    player = current; previewing = voice.id
    let request = generation
    observers = [
      NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.finish(request: request, failure: nil) }
      },
      NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.finish(request: request, failure: "试听中断，请重试") }
      },
      NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.finish(request: request, failure: "试听播放失败，请重试") }
      }
    ]
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      let failed = item.status == .failed
      if failed { Task { @MainActor in self?.finish(request: request, failure: "试听加载失败，请重试") } }
    }
    startPlayback(current)
  }

  func stop() {
    if Self.current === self { Self.current = nil }
    generation = UUID()
    statusObservation = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    previewing = nil; error = nil
  }

  private func finish(request: UUID, failure: String?) {
    guard generation == request else { return }
    stop(); error = failure
  }
}
