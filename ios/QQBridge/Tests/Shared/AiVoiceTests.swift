import AVFoundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor
private final class VoiceReplies: AiVoiceService {
  private(set) var loads = 0
  private(set) var sends: [(String, String)] = []
  private var loadReplies: [Int: CheckedContinuation<[Qqbridge_V1_AiVoiceCategory], any Error>] = [:]
  private var sendReplies: [Int: CheckedContinuation<Void, any Error>] = [:]
  func categories() async throws -> [Qqbridge_V1_AiVoiceCategory] {
    let id = loads; loads += 1
    return try await withCheckedThrowingContinuation { loadReplies[id] = $0 }
  }
  func send(voiceId: String, text: String) async throws {
    let id = sends.count; sends.append((voiceId, text))
    try await withCheckedThrowingContinuation { sendReplies[id] = $0 }
  }
  func loaded(_ id: Int, _ values: [Qqbridge_V1_AiVoiceCategory]) { loadReplies.removeValue(forKey: id)?.resume(returning: values) }
  func loadFailed(_ id: Int) { loadReplies.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut)) }
  func sent(_ id: Int) { sendReplies.removeValue(forKey: id)?.resume() }
  func sendFailed(_ id: Int) { sendReplies.removeValue(forKey: id)?.resume(throwing: URLError(.notConnectedToInternet)) }
}

private func voice(_ id: String) -> Qqbridge_V1_AiVoice {
  var v = Qqbridge_V1_AiVoice(); v.id = id; v.name = id; v.previewURL = "https://example.invalid/\(id).mp3"; return v
}
private func category(_ name: String, _ ids: [String]) -> Qqbridge_V1_AiVoiceCategory {
  var c = Qqbridge_V1_AiVoiceCategory(); c.name = name; c.voices = ids.map(voice); return c
}
@MainActor private func waitForVoice(_ predicate: () -> Bool) async {
  let deadline = ContinuousClock.now + .seconds(3)
  while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
  #expect(predicate())
}

@Suite(.serialized) @MainActor
struct AiVoiceTests {
  @Test func failedLoadRetriesWithoutReplacingEditedDraft() async {
    let service = VoiceReplies()
    let actual = AiVoiceViewModel(service: service, text: "初始")
    let first = actual.load(); await waitForVoice { service.loads == 1 }
    actual.text = "编辑后的文字"
    service.loadFailed(0); await first?.value
    #expect(actual.loadError != nil && actual.text == "编辑后的文字" && !actual.canSend)
    let next = actual.load(); let duplicate = actual.load(); await waitForVoice { service.loads == 2 }
    service.loaded(1, [category("普通", ["a"])])
    await next?.value; await duplicate?.value
    #expect(actual.loadError == nil && actual.text == "编辑后的文字" && actual.voiceId == "a" && service.loads == 2)
  }

  @Test func categorySwitchCannotSendHiddenRoleAndEmptyCategoryDisablesSend() async {
    let service = VoiceReplies()
    let actual = AiVoiceViewModel(service: service, text: "  你好  ")
    let load = actual.load(); await waitForVoice { service.loads == 1 }
    service.loaded(0, [category("甲", ["a", "a2"]), category("乙", ["b"]), category("空", [])]); await load?.value
    actual.selectVoice("a2"); actual.selectCategory(1)
    #expect(actual.voiceId == "b" && actual.canSend)
    actual.selectVoice("a")
    #expect(actual.voiceId == "b")
    actual.selectCategory(2)
    #expect(actual.voiceId == nil && !actual.canSend && actual.send { _ in } == nil)
    actual.selectCategory(1)
    var confirmed: [String] = []
    let send = actual.send { confirmed.append($0) }
    #expect(actual.send { _ in Issue.record("不应重复发送") } == nil)
    actual.selectCategory(0); actual.selectVoice("a")
    await waitForVoice { service.sends.count == 1 }
    #expect(service.sends[0].0 == "b" && service.sends[0].1 == "你好" && actual.voiceId == "b")
    service.sent(0); await send?.value
    #expect(confirmed == ["你好"] && !actual.isSending)
  }

  @Test func refreshPreservesRoleByCategoryNameAndFailureKeepsChoices() async {
    let service = VoiceReplies()
    let actual = AiVoiceViewModel(service: service, text: "草稿")
    let first = actual.load(); await waitForVoice { service.loads == 1 }
    service.loaded(0, [category("甲", ["a", "a2"]), category("乙", ["b"])]); await first?.value
    actual.selectVoice("a2")
    let refresh = actual.load(); await waitForVoice { service.loads == 2 }
    service.loaded(1, [category("乙", ["b"]), category("甲", ["a2"])]); await refresh?.value
    #expect(actual.category == 1 && actual.voiceId == "a2")
    let failed = actual.load(); await waitForVoice { service.loads == 3 }
    service.loadFailed(2); await failed?.value
    #expect(actual.category == 1 && actual.voiceId == "a2" && actual.text == "草稿" && actual.loadError != nil)
  }

  @Test(arguments: [false, true]) func cancelledLoadCannotReplaceNextPage(fail: Bool) async {
    let service = VoiceReplies()
    let actual = AiVoiceViewModel(service: service, text: "草稿")
    let first = actual.load(); await waitForVoice { service.loads == 1 }; actual.cancel()
    let next = actual.load(); await waitForVoice { service.loads == 2 }
    if fail { service.loadFailed(0) } else { service.loaded(0, [category("旧", ["old"])]) }
    await first?.value
    #expect(actual.isLoading && actual.categories.isEmpty && actual.loadError == nil)
    service.loaded(1, [category("新", ["new"])]); await next?.value
    #expect(actual.voiceId == "new" && !actual.isLoading)
  }

  @Test(arguments: [false, true]) func closeIgnoresLateSendResult(fail: Bool) async {
    let service = VoiceReplies(); let model = AiVoiceViewModel(service: service, text: "草稿")
    let load = model.load(); await waitForVoice { service.loads == 1 }
    service.loaded(0, [category("甲", ["a"])]); await load?.value
    var notified = false
    let send = model.send { _ in notified = true }; await waitForVoice { service.sends.count == 1 }
    model.cancel()
    #expect(model.isSending && model.send { _ in } == nil)
    if fail { service.sendFailed(0) } else { service.sent(0) }
    await send?.value
    #expect(!notified && !model.isSending && model.text == "草稿")
    #expect((model.sendError != nil) == fail)
    var returned = 0
    model.resume { _ in returned += 1 }; model.resume { _ in returned += 1 }
    #expect(returned == (fail ? 0 : 1))
    #expect(model.canSend == fail)
  }

  @Test func sendFailurePreservesChoiceAndRequiresExplicitRetry() async {
    let service = VoiceReplies(); let model = AiVoiceViewModel(service: service, text: "草稿")
    let load = model.load(); await waitForVoice { service.loads == 1 }
    service.loaded(0, [category("空", []), category("甲", ["a"])]); await load?.value
    #expect(model.category == 1)
    let send = model.send { _ in Issue.record("失败不能确认发送") }; await waitForVoice { service.sends.count == 1 }
    service.sendFailed(0); await send?.value
    #expect(model.sendError != nil && model.voiceId == "a" && model.text == "草稿" && model.canSend && service.sends.count == 1)
  }

  @Test func previewEndAndFailureClearPlayingState() async {
    let preview = AiVoicePreview(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) }, startPlayback: { _ in }, configureAudio: {})
    preview.toggle(voice("a")); let first = preview.player?.currentItem
    #expect(preview.previewing == "a")
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first)
    await waitForVoice { preview.previewing == nil }
    #expect(preview.player == nil && preview.error == nil)
    preview.toggle(voice("b")); let second = preview.player?.currentItem
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: second)
    await waitForVoice { preview.error != nil }
    #expect(preview.player == nil && preview.previewing == nil && preview.error == "试听播放失败，请重试")
  }

  @Test func oldPreviewNotificationCannotStopReplacementAndCloseReleasesItem() async {
    let preview = AiVoicePreview(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) }, startPlayback: { _ in }, configureAudio: {})
    preview.toggle(voice("a")); let first = preview.player
    NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: first?.currentItem)
    preview.toggle(voice("b"))
    await Task.yield(); await Task.yield()
    #expect(preview.previewing == "b" && first?.currentItem == nil)
    let current = preview.player
    preview.stop()
    #expect(preview.previewing == nil && preview.player == nil && current?.currentItem == nil)
  }

  @Test func stalledPreviewOffersRetryAndAudioSetupFailureDoesNotStartPlayer() async {
    let preview = AiVoicePreview(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) }, startPlayback: { _ in }, configureAudio: {})
    preview.toggle(voice("a"))
    NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: preview.player?.currentItem)
    await waitForVoice { preview.previewing == nil }
    #expect(preview.error == "试听中断，请重试" && preview.player == nil)
    let denied = AiVoicePreview(makePlayer: { _ in Issue.record("配置失败不能创建播放器"); return AVPlayer() }, configureAudio: { throw URLError(.unknown) })
    denied.toggle(voice("a"))
    #expect(denied.previewing == nil && denied.error != nil && denied.player == nil)
  }

  @Test func duplicateStartAndReloadedEmptyCategoryKeepDraftAndPreventSending() async {
    let service = VoiceReplies(); let model = AiVoiceViewModel(service: service, text: "草稿")
    model.start(); model.start(); await waitForVoice { service.loads == 1 }
    service.loaded(0, [category("甲", ["a"])])
    await waitForVoice { model.hasLoaded }
    let refresh = model.load(); await waitForVoice { service.loads == 2 }
    #expect(model.send { _ in } == nil)
    service.loaded(1, []); await refresh?.value
    #expect(model.categories.isEmpty && model.voiceId == nil && !model.canSend && model.text == "草稿")
  }

  @Test func missingLocalAssetReportsInitialPlayerFailure() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ai-preview-missing-\(UUID().uuidString).wav")
    let preview = AiVoicePreview(makePlayer: { _ in AVPlayer(url: missing) }, configureAudio: {})
    preview.toggle(voice("a"))
    await waitForVoice { preview.error != nil }
    #expect(preview.error == "试听加载失败，请重试" && preview.previewing == nil && preview.player == nil)
  }

  @Test func invalidPreviewURLStopsOldPlayerAndReportsFailure() {
    let preview = AiVoicePreview(makePlayer: { _ in AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition())) }, startPlayback: { _ in }, configureAudio: {})
    preview.toggle(voice("a")); let first = preview.player
    var invalid = voice("b"); invalid.previewURL = "not a URL"
    preview.toggle(invalid)
    #expect(preview.error != nil && preview.previewing == nil && first?.currentItem == nil)
  }
}
