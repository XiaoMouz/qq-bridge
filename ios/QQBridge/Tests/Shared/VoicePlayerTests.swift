import AVFoundation
import QQBridgeProto
import Observation
import Testing
@testable import BetterChat

@MainActor private final class PlaybackReplies: VoicePlaybackSource {
  var calls: [String] = []
  private var replies: [Int: CheckedContinuation<URL, any Error>] = [:]
  func source(for sha: String) async throws -> URL {
    let id = calls.count; calls.append(sha)
    return try await withCheckedThrowingContinuation { replies[id] = $0 }
  }
  func finish(_ id: Int, url: URL = URL(fileURLWithPath: "/nonexistent-voice.m4a")) { replies.removeValue(forKey: id)?.resume(returning: url) }
  func fail(_ id: Int) { replies.removeValue(forKey: id)?.resume(throwing: URLError(.notConnectedToInternet)) }
}
private func record(_ sha: String) -> Qqbridge_V1_RecordSegment {
  var value = Qqbridge_V1_RecordSegment(); value.media.sha256 = sha; value.durationSec = 30
  return value
}
@MainActor private func waitForPlayback(_ condition: () -> Bool) async {
  let limit = ContinuousClock.now + .seconds(3)
  while !condition(), ContinuousClock.now < limit { await Task.yield() }
  #expect(condition())
}
@MainActor private func silentPlayer() -> VoicePlayer {
  VoicePlayer(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) },
              startPlayback: { _ in }, configureAudio: {})
}
@MainActor private final class PlaybackObservation { var changed = false }

@Suite(.serialized) @MainActor
struct VoicePlayerTests {
  @Test func previewAndMessagesStopEachOtherIncludingPendingLoads() async {
    let source = PlaybackReplies(); let model = silentPlayer()
    let preview = AiVoicePreview(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) },
                                 startPlayback: { _ in }, configureAudio: {})
    var sample = Qqbridge_V1_AiVoice(); sample.id = "preview"; sample.previewURL = "https://example.invalid/preview.m4a"
    let pending = model.toggle(record("pending"), source: source)
    await waitForPlayback { source.calls.count == 1 }
    preview.toggle(sample)
    #expect(model.playing == nil && pending?.isCancelled == true && preview.previewing == "preview")
    source.finish(0); await pending?.value
    #expect(model.player == nil && preview.player != nil)
    let next = model.toggle(record("next"), source: source)
    #expect(preview.previewing == nil && preview.player == nil)
    await waitForPlayback { source.calls.count == 2 }
    source.finish(1); await next?.value
    #expect(model.player != nil)
    preview.toggle(sample)
    #expect(model.player == nil && preview.player != nil)
    preview.stop(); model.stop()
  }

  @Test(arguments: [false, true]) func sameMediaReopenRejectsOldSource(fail: Bool) async {
    let source = PlaybackReplies(); let model = silentPlayer(); let value = record("same")
    let old = model.toggle(value, source: source)
    await waitForPlayback { source.calls.count == 1 }
    model.toggle(value, source: source)
    #expect(old?.isCancelled == true && model.playing == nil)
    let current = model.toggle(value, source: source)
    await waitForPlayback { source.calls.count == 2 }
    if fail { source.fail(0) } else { source.finish(0) }
    await old?.value
    #expect(model.playing == "same" && model.player == nil && model.failure == nil && model.isLoading)
    source.finish(1); await current?.value
    #expect(model.player != nil && model.failure == nil)
    model.stop()
  }

  @Test func closingWhileResolvingCannotStartAudioLater() async {
    let source = PlaybackReplies(); var configured = 0
    let model = VoicePlayer(configureAudio: { configured += 1 })
    let task = model.toggle(record("closed"), source: source)
    await waitForPlayback { source.calls.count == 1 }
    model.stop(); source.finish(0); await task?.value
    #expect(configured == 0 && model.player == nil && model.playing == nil && !model.isLoading)
  }

  @Test func sourceFailureLeavesRetryableState() async {
    let source = PlaybackReplies(); let model = silentPlayer(); let value = record("retry")
    let task = model.toggle(value, source: source)
    await waitForPlayback { source.calls.count == 1 }; source.fail(0); await task?.value
    #expect(model.error(for: value) != nil && !model.isPlaying(value) && !model.isLoading)
    #expect(model.error(for: record("other")) == nil)
    let retry = model.toggle(value, source: source)
    await waitForPlayback { source.calls.count == 2 }; source.finish(1); await retry?.value
    #expect(model.error(for: value) == nil && model.isPlaying(value) && model.player != nil)
    model.stop()
  }

  @Test(arguments: [0, 1]) func completionAndFailureReleasePlayer(event: Int) async {
    let source = PlaybackReplies(); let model = silentPlayer(); let value = record("events")
    let task = model.toggle(value, source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await task?.value
    let player = model.player; let item = player?.currentItem
    model.waveFrame = CGRect(x: 0, y: 0, width: 100, height: 40)
    let name: Notification.Name = [.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime][event]
    NotificationCenter.default.post(name: name, object: item)
    await waitForPlayback { model.playing == nil }
    #expect(model.player == nil && player?.currentItem == nil && model.waveFrame == nil && !model.scrubbing)
    #expect((model.failure == nil) == (event == 0))
  }

  @Test func queuedOldNotificationCannotStopReplacementPlayer() async {
    let source = PlaybackReplies(); let model = silentPlayer()
    let first = model.toggle(record("old"), source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await first?.value
    let item = model.player?.currentItem
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    let next = model.toggle(record("new"), source: source)
    await waitForPlayback { source.calls.count == 2 }; source.finish(1); await next?.value
    #expect(model.playing == "new" && model.player != nil && model.failure == nil)
    model.stop()
  }

  @Test func seekCompletionCannotEndNewDragAndCancellationDoesNotSeek() async {
    let source = PlaybackReplies()
    var completions: [@Sendable (Bool) -> Void] = []; var times: [Double] = []
    let model = VoicePlayer(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) },
                            startPlayback: { _ in }, configureAudio: {}, seek: { _, time, completion in
      times.append(time.seconds); completions.append(completion)
    })
    let first = model.toggle(record("same"), source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await first?.value
    model.scrub(to: 0.25); model.endScrub()
    #expect(times == [7.5] && model.scrubbing)
    model.scrub(to: 0.75)
    completions[0](true)
    // 系统 seek 回调经 MainActor 入队；让事件循环实际处理旧回调后检查新拖动未结束。
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.scrubbing && model.progress == 0.75)
    model.cancelScrub()
    #expect(!model.scrubbing && times.count == 1)
    model.scrub(to: 0.5); model.endScrub()
    model.stop()
    let replacement = model.toggle(record("same"), source: source)
    await waitForPlayback { source.calls.count == 2 }; source.finish(1); await replacement?.value
    model.scrub(to: 0.8); completions[1](true)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.scrubbing && model.progress == 0.8)
    model.endScrub(); completions[2](true)
    await waitForPlayback { !model.scrubbing }
    model.stop(); model.scrub(to: 0.5)
    #expect(!model.scrubbing && model.progress == 0)
  }

  @Test func unresolvedLoadTimesOutAndRejectsLateSuccess() async {
    let source = PlaybackReplies()
    let model = VoicePlayer(configureAudio: { Issue.record("超时后不能配置音频") }, loadTimeout: .milliseconds(20))
    let task = model.toggle(record("timeout"), source: source)
    await waitForPlayback { source.calls.count == 1 }
    await waitForPlayback { model.failure != nil }
    #expect(model.failure == "语音加载超时，请重试" && !model.isLoading && model.playing == nil)
    source.finish(0); await task?.value
    #expect(model.player == nil && model.failure == "语音加载超时，请重试")
  }

  @Test func audioConfigurationFailureDoesNotLeavePlayingState() async {
    let source = PlaybackReplies()
    let model = VoicePlayer(configureAudio: { throw URLError(.cannotOpenFile) })
    let task = model.toggle(record("audio-error"), source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await task?.value
    #expect(model.player == nil && model.playing == nil && model.failure == "无法启用音频播放，请稍后重试" && !model.isLoading)
  }

  @Test func initialAVPlayerFailureIsObserved() async {
    let source = PlaybackReplies(); let model = VoicePlayer(startPlayback: { _ in }, configureAudio: {})
    let task = model.toggle(record("missing-file"), source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await task?.value
    await waitForPlayback { model.failure != nil }
    #expect(model.failure == "语音加载失败，请重试" && model.player == nil && model.playing == nil)
  }

  @Test func duplicateMediaMessagesHaveSeparatePlaybackAndWaveFrames() async {
    let source = PlaybackReplies(); let model = silentPlayer(); let value = record("duplicated")
    let firstID = VoicePlaybackID(chatId: 153, seq: 10, block: 0)
    let secondID = VoicePlaybackID(chatId: 153, seq: 11, block: 0)
    let first = model.toggle(value, id: firstID, source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await first?.value
    #expect(model.isPlaying(value, id: firstID) && !model.isPlaying(value, id: secondID))
    let firstPlayer = model.player
    let second = model.toggle(value, id: secondID, source: source)
    await waitForPlayback { source.calls.count == 2 }; source.finish(1); await second?.value
    #expect(!model.isPlaying(value, id: firstID) && model.isPlaying(value, id: secondID))
    #expect(firstPlayer?.currentItem == nil)
    let frame = CGRect(x: 1, y: 2, width: 100, height: 20)
    model.reportWaveFrame(frame, id: secondID); model.reportWaveFrame(nil, id: firstID)
    #expect(model.waveFrame == frame)
    model.reportWaveFrame(nil, id: secondID)
    #expect(model.waveFrame == nil)
    model.stop()
  }

  @Test func anotherChatPlayerStopsPreviousWithoutLateReplacement() async {
    let source = PlaybackReplies(); let first = silentPlayer(); let second = silentPlayer()
    let old = first.toggle(record("first"), source: source)
    await waitForPlayback { source.calls.count == 1 }
    let current = second.toggle(record("second"), source: source)
    await waitForPlayback { source.calls.count == 2 }
    #expect(first.playing == nil && old?.isCancelled == true)
    source.finish(0); await old?.value; source.finish(1); await current?.value
    first.stop()
    #expect(second.playing == "second" && second.player != nil)
    VoicePlayer.stopCurrent()
    #expect(second.playing == nil && second.player == nil)
  }

  @Test func audioInterruptionStopsPlaybackAndAllowsRestart() async {
    let source = PlaybackReplies(); let model = silentPlayer()
    let first = model.toggle(record("interrupted"), source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await first?.value
    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    await waitForPlayback { model.playing == nil }
    #expect(model.player == nil && !model.isLoading && model.failure == nil)
    let second = model.toggle(record("resumed"), source: source)
    await waitForPlayback { source.calls.count == 2 }; source.finish(1); await second?.value
    #expect(model.playing == "resumed")
    model.stop()
  }

  @Test func failureLookupObservesChangesBeforeThereIsAnError() async {
    let source = PlaybackReplies(); let model = silentPlayer(); let value = record("observed")
    let id = VoicePlaybackID(chatId: 153, seq: 88, block: 0)
    let observation = PlaybackObservation()
    withObservationTracking {
      #expect(model.error(for: value, id: id) == nil)
    } onChange: {
      Task { @MainActor in observation.changed = true }
    }
    let task = model.toggle(value, id: id, source: source)
    await waitForPlayback { source.calls.count == 1 }; source.fail(0); await task?.value
    await waitForPlayback { observation.changed }
    #expect(model.error(for: value, id: id) == "语音加载失败，请重试")
  }

  @Test func stalledPlaybackCanRecoverWithoutRecreatingPlayer() async {
    let source = PlaybackReplies(); let model = silentPlayer()
    let task = model.toggle(record("buffering"), source: source)
    await waitForPlayback { source.calls.count == 1 }; source.finish(0); await task?.value
    let player = model.player
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: player?.currentItem)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.player === player && model.playing == "buffering" && model.failure == nil)
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
    await waitForPlayback { model.playing == nil }
  }

  @Test func truncatedTemporaryCopyIsRebuiltFromCache() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceFileTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("cache"); let data = Data(repeating: 42, count: 1024)
    try data.write(to: file)
    let truncated = directory.appendingPathComponent("voice-sha.m4a"); try Data([42]).write(to: truncated)
    let repaired = try SessionVoicePlaybackSource.playableFile(for: file, sha: "sha", directory: directory)
    let copied = try Data(contentsOf: repaired)
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(repaired == truncated && copied == data)
    #expect(entries.count == 2)
  }

  @Test func pendingRecordingPermissionReservesAudioUntilCancelled() async {
    var permission: CheckedContinuation<Bool, Never>?
    let first = VoiceRecorder(requestPermission: { await withCheckedContinuation { permission = $0 } })
    let second = VoiceRecorder(requestPermission: { Issue.record("不能请求第二次授权"); return false })
    let pending = Task { try? await first.start() }
    await waitForPlayback { permission != nil }
    #expect(VoiceRecorder.isBusy)
    do { try await second.start(); Issue.record("第二个录音器应拒绝启动") } catch { #expect(error == .unavailable) }
    first.cancel(); #expect(!VoiceRecorder.isBusy)
    permission?.resume(returning: false); await pending.value
    #expect(!VoiceRecorder.isBusy && !first.recording)
  }
}
