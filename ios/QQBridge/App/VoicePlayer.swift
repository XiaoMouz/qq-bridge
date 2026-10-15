import AVFoundation
import Observation
import QQBridgeKit
import QQBridgeProto

struct VoicePlaybackID: Hashable {
  let chatId: Int64
  let seq: Int64
  let block: Int
}

@MainActor
protocol VoicePlaybackSource {
  func source(for sha: String) async throws -> URL
}

@MainActor
struct SessionVoicePlaybackSource: VoicePlaybackSource {
  let session: Session
  func source(for sha: String) async throws -> URL {
    do {
      // 先完整缓存，拖动才不依赖网络；扩展名副本供 AVFoundation 识别 AAC 容器。
      let file = try await session.media.file(for: sha, chatId: nil)
      try Task.checkCancellation()
      return try Self.playableFile(for: file, sha: sha)
    } catch {
      try Task.checkCancellation()
      // 包括副本写入失败；不能把不存在的临时路径交给播放器。
      return try await session.media.streamURL(for: sha)
    }
  }

  static func playableFile(for file: URL, sha: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let manager = FileManager.default
    let named = directory.appendingPathComponent("voice-\(sha).m4a")
    let size = try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber
    let copiedSize = (try? manager.attributesOfItem(atPath: named.path)[.size]) as? NSNumber
    if size != nil, size == copiedSize { return named }
    let staging = directory.appendingPathComponent("voice-copy-\(UUID()).m4a")
    defer { try? manager.removeItem(at: staging) }
    try manager.copyItem(at: file, to: staging)
    if manager.fileExists(atPath: named.path) { try manager.removeItem(at: named) }
    try manager.moveItem(at: staging, to: named)
    return named
  }
}

/// 同一聊天页只播放一条语音。下载、播放器通知和 seek 都按一次操作归属，不能只比较媒体 sha。
@MainActor @Observable
final class VoicePlayer {
  private enum AudioError: Error { case recordingInProgress }
  private static weak var current: VoicePlayer?
  static func stopCurrent() { current?.stop() }
  private(set) var playing: String?
  private(set) var playingID: VoicePlaybackID?
  private(set) var progress: Double = 0
  private(set) var duration: Double = 0
  private(set) var scrubbing = false
  private(set) var isLoading = false
  private(set) var failure: String?
  @ObservationIgnored private var failedSHA: String?
  @ObservationIgnored private var failedID: VoicePlaybackID?
  @ObservationIgnored var waveFrame: CGRect?
  @ObservationIgnored private(set) var player: AVPlayer?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  var playbackRequest: UUID { generation }
  @ObservationIgnored private var seekGeneration = UUID()
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var ticker: Any?
  @ObservationIgnored private let makePlayer: (URL) -> AVPlayer
  @ObservationIgnored private let startPlayback: (AVPlayer) -> Void
  @ObservationIgnored private let configureAudio: () throws -> Void
  @ObservationIgnored private let seek: (AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void) -> Void
  @ObservationIgnored private let loadTimeout: Duration

  init(makePlayer: @escaping (URL) -> AVPlayer = { AVPlayer(url: $0) },
       startPlayback: @escaping (AVPlayer) -> Void = { $0.play() },
       configureAudio: @escaping () throws -> Void = {
         guard !VoiceRecorder.isBusy else { throw AudioError.recordingInProgress }
         try AVAudioSession.sharedInstance().setCategory(.playback)
         try AVAudioSession.sharedInstance().setActive(true)
       },
       seek: @escaping (AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void) -> Void = { player, time, completion in
         player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion)
       }, loadTimeout: Duration = .seconds(30)) {
    self.makePlayer = makePlayer; self.startPlayback = startPlayback; self.configureAudio = configureAudio
    self.seek = seek; self.loadTimeout = loadTimeout
  }

  isolated deinit {
    loadTask?.cancel(); timeoutTask?.cancel()
    if let ticker { player?.removeTimeObserver(ticker) }
    player?.pause()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  static func sha(_ record: Qqbridge_V1_RecordSegment) -> String {
    record.media.playableSha256.isEmpty ? record.media.sha256 : record.media.playableSha256
  }
  func isPlaying(_ record: Qqbridge_V1_RecordSegment, id: VoicePlaybackID? = nil) -> Bool {
    guard let playing else { return false }
    return playingID == id && (playing == Self.sha(record) || playing == record.media.sha256)
  }
  func error(for record: Qqbridge_V1_RecordSegment, id: VoicePlaybackID? = nil) -> String? {
    // 即使尚无错误，也登记对 failure 的观察；先短路身份判断会让 SwiftUI 永远不订阅错误变化。
    let message = failure
    return failedID == id && failedSHA == Self.sha(record) ? message : nil
  }
  func reportWaveFrame(_ frame: CGRect?, id: VoicePlaybackID?) {
    if playingID == id { waveFrame = frame }
  }
  func toggle(_ record: Qqbridge_V1_RecordSegment, id: VoicePlaybackID? = nil, session: Session) {
    toggle(record, id: id, source: SessionVoicePlaybackSource(session: session))
  }

  @discardableResult
  func toggle(_ record: Qqbridge_V1_RecordSegment, id: VoicePlaybackID? = nil, source: any VoicePlaybackSource) -> Task<Void, Never>? {
    let sha = Self.sha(record)
    if isPlaying(record, id: id) { stop(); return nil }
    stop()
    guard !sha.isEmpty else { failedSHA = sha; failedID = id; failure = "语音文件不可用"; return nil }
    AiVoicePreview.stopCurrent()
    Self.current?.stop(); Self.current = self
    playing = sha; playingID = id; duration = max(0, Double(record.durationSec)); isLoading = true
    let request = generation
    timeoutTask = Task { [weak self, loadTimeout] in
      do { try await Task.sleep(for: loadTimeout) } catch { return }
      self?.finish(request: request, sha: sha, failure: "语音加载超时，请重试")
    }
    let task = Task { [weak self] in
      do {
        let url = try await source.source(for: sha)
        guard let self, generation == request, !Task.isCancelled else { return }
        do { try configureAudio() } catch {
          finish(request: request, sha: sha, failure: "无法启用音频播放，请稍后重试"); return
        }
        let player = makePlayer(url)
        guard let item = player.currentItem else {
          finish(request: request, sha: sha, failure: "语音文件不可用，请重试"); return
        }
        self.player = player; loadTask = nil
        observe(item: item, player: player, request: request, sha: sha)
        startPlayback(player)
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        finish(request: request, sha: sha, failure: "语音加载失败，请重试")
      }
    }
    loadTask = task
    return task
  }

  private func observe(item: AVPlayerItem, player: AVPlayer, request: UUID, sha: String) {
    let events: [(Notification.Name, String?)] = [
      (.AVPlayerItemDidPlayToEndTime, nil),
      (.AVPlayerItemFailedToPlayToEndTime, "语音播放失败，请重试")
    ]
    observers = events.map { name, reason in
      NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.finish(request: request, sha: sha, failure: reason) }
      }
    }
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
      let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
      if began { Task { @MainActor in self?.finish(request: request, sha: sha, failure: nil) } }
    })
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      let ready = item.status == .readyToPlay
      let failed = item.status == .failed
      Task { @MainActor in
        guard let self, self.generation == request else { return }
        if ready { self.isLoading = false; self.timeoutTask?.cancel(); self.timeoutTask = nil }
        if failed { self.finish(request: request, sha: sha, failure: "语音加载失败，请重试") }
      }
    }
    ticker = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self, weak player] time in
      MainActor.assumeIsolated {
        guard let self, self.generation == request, !self.scrubbing else { return }
        let total = player?.currentItem?.duration.seconds ?? .nan
        if total.isFinite, total > 0 { self.duration = total }
        self.updateProgress(seconds: time.seconds)
      }
    }
  }

  func scrub(to fraction: Double) {
    guard player != nil, duration > 0, fraction.isFinite else { return }
    seekGeneration = UUID()
    scrubbing = true; progress = min(1, max(0, fraction))
  }

  func endScrub() {
    guard scrubbing, let player, duration > 0 else { scrubbing = false; return }
    let request = generation; let seekID = UUID(); seekGeneration = seekID
    seek(player, CMTime(seconds: progress * duration, preferredTimescale: 600)) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == request, self.seekGeneration == seekID else { return }
        self.scrubbing = false
      }
    }
  }

  func cancelScrub() {
    seekGeneration = UUID(); scrubbing = false
    updateProgress(seconds: player?.currentTime().seconds ?? 0)
  }

  private func updateProgress(seconds: Double) {
    guard duration > 0, seconds.isFinite else { return }
    progress = min(1, max(0, seconds / duration))
  }

  func stop() {
    if Self.current === self { Self.current = nil }
    generation = UUID(); seekGeneration = UUID()
    loadTask?.cancel(); loadTask = nil; timeoutTask?.cancel(); timeoutTask = nil
    statusObservation = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let ticker { player?.removeTimeObserver(ticker) }
    ticker = nil
    player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    playing = nil; playingID = nil; progress = 0; duration = 0; scrubbing = false; waveFrame = nil; isLoading = false
    failure = nil; failedSHA = nil; failedID = nil
  }

  private func finish(request: UUID, sha: String, failure: String?) {
    guard generation == request else { return }
    let id = playingID
    stop()
    self.failure = failure; failedSHA = failure == nil ? nil : sha; failedID = failure == nil ? nil : id
  }
}
