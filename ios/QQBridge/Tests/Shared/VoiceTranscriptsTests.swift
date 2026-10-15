import Foundation
import Testing
@testable import BetterChat

@MainActor private final class TranscriptReplies: VoiceTranscriptionService {
  var calls: [(Int64, Int64)] = []
  var replies: [Int: CheckedContinuation<String, any Error>] = [:]
  func transcribe(chatId: Int64, seq: Int64) async throws -> String {
    let index = calls.count; calls.append((chatId, seq))
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }
  func finish(_ index: Int, _ text: String) { replies.removeValue(forKey: index)?.resume(returning: text) }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.notConnectedToInternet)) }
}

@MainActor private func waitForTranscript(_ condition: () -> Bool) async {
  let deadline = ContinuousClock.now + .seconds(3)
  while !condition(), ContinuousClock.now < deadline { await Task.yield() }
  #expect(condition())
}

@Suite(.serialized) @MainActor
struct VoiceTranscriptsTests {
  private func isolatedDefaults() -> (String, UserDefaults) {
    let name = "BetterChat.Transcripts.Tests.\(UUID())"
    return (name, UserDefaults(suiteName: name)!)
  }

  @Test(arguments: ["识别后的完整文字", ""]) func hidingAndReopeningUsesPersistedResult(text: String) async {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = TranscriptReplies(); let model = VoiceTranscripts(defaults: defaults)
    let task = model.transcribe(chatId: 153, seq: 7, service: service)
    await waitForTranscript { service.calls.count == 1 }; service.finish(0, text); await task?.value
    model.toggle(chatId: 153, seq: 7, service: service)
    #expect(model.state(chatId: 153, seq: 7) == nil)
    #expect(defaults.dictionary(forKey: "voiceTranscripts")?["153:7"] as? String == text)
    model.toggle(chatId: 153, seq: 7, service: service)
    #expect(model.state(chatId: 153, seq: 7) == .text(text) && service.calls.count == 1)
    model.hide(chatId: 153, seq: 7)
    let restored = VoiceTranscripts(defaults: defaults)
    #expect(restored.state(chatId: 153, seq: 7) == nil)
    #expect(restored.transcribe(chatId: 153, seq: 7, service: service) == nil)
    #expect(restored.state(chatId: 153, seq: 7) == .text(text) && service.calls.count == 1)
  }

  @Test func duplicateRequestsCoalesceAndFailureRetriesManually() async {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: VoiceTranscripts.autoKey)
    let service = TranscriptReplies(); let model = VoiceTranscripts(defaults: defaults)
    let first = model.transcribe(chatId: 153, seq: 8, service: service)
    let second = model.transcribe(chatId: 153, seq: 8, service: service)
    model.toggle(chatId: 153, seq: 8, service: service)
    await waitForTranscript { service.calls.count == 1 }; service.fail(0)
    await first?.value; await second?.value
    #expect(model.state(chatId: 153, seq: 8) == .failed("网络连接不可用，请稍后重试"))
    model.autoTranscribe(chatId: 153, seq: 8, service: service)
    #expect(service.calls.count == 1)
    let retry = model.transcribe(chatId: 153, seq: 8, service: service)
    await waitForTranscript { service.calls.count == 2 }; service.finish(1, "重试成功"); await retry?.value
    #expect(model.state(chatId: 153, seq: 8) == .text("重试成功"))
  }

  @Test(arguments: [false, true]) func hidingPendingRequestIsolatesLateCompletion(failure: Bool) async {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = TranscriptReplies(); let model = VoiceTranscripts(defaults: defaults)
    let old = model.transcribe(chatId: 153, seq: 9, service: service)
    await waitForTranscript { service.calls.count == 1 }; model.hide(chatId: 153, seq: 9)
    #expect(old?.isCancelled == true && model.state(chatId: 153, seq: 9) == nil)
    let current = model.transcribe(chatId: 153, seq: 9, service: service)
    await waitForTranscript { service.calls.count == 2 }
    if failure { service.fail(0) } else { service.finish(0, "旧结果") }
    await old?.value
    #expect(model.state(chatId: 153, seq: 9) == .loading)
    #expect(defaults.dictionary(forKey: "voiceTranscripts") == nil)
    service.finish(1, "最新结果"); await current?.value
    #expect(model.state(chatId: 153, seq: 9) == .text("最新结果"))
  }

  @Test func automaticTranscriptionRespectsPreferenceAndManualHide() async {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = TranscriptReplies(); let model = VoiceTranscripts(defaults: defaults)
    model.autoTranscribe(chatId: 153, seq: 10, service: service)
    #expect(model.state(chatId: 153, seq: 10) == nil)
    defaults.set(true, forKey: VoiceTranscripts.autoKey)
    model.autoTranscribe(chatId: 153, seq: 10, service: service)
    await waitForTranscript { service.calls.count == 1 }; service.finish(0, "保留结果")
    await waitForTranscript { model.state(chatId: 153, seq: 10) == .text("保留结果") }
    model.hide(chatId: 153, seq: 10)
    model.autoTranscribe(chatId: 153, seq: 10, service: service)
    #expect(model.state(chatId: 153, seq: 10) == nil && service.calls.count == 1)
    model.toggle(chatId: 153, seq: 10, service: service)
    #expect(model.state(chatId: 153, seq: 10) == .text("保留结果"))
  }

  @Test func sameSequenceInDifferentChatsKeepsIndependentResults() async {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    let service = TranscriptReplies(); let model = VoiceTranscripts(defaults: defaults)
    let first = model.transcribe(chatId: 1, seq: 1, service: service)
    await waitForTranscript { service.calls.count == 1 }
    let second = model.transcribe(chatId: 2, seq: 1, service: service)
    await waitForTranscript { service.calls.count == 2 }
    service.finish(1, "乙"); await second?.value
    service.finish(0, "甲"); await first?.value
    model.hide(chatId: 1, seq: 1)
    #expect(model.state(chatId: 2, seq: 1) == .text("乙"))
    #expect(defaults.dictionary(forKey: "voiceTranscripts")?.count == 2)
  }

  @Test func oldCacheFormatAndDiskLimitRemainCompatible() async {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(Dictionary(uniqueKeysWithValues: (1...500).map { ("153:\($0)", "旧缓存\($0)") }), forKey: "voiceTranscripts")
    let service = TranscriptReplies(); let model = VoiceTranscripts(defaults: defaults)
    #expect(model.state(chatId: 153, seq: 2) == .text("旧缓存2"))
    let new = model.transcribe(chatId: 153, seq: 999, service: service)
    await waitForTranscript { service.calls.count == 1 }; service.finish(0, "新结果"); await new?.value
    #expect(defaults.dictionary(forKey: "voiceTranscripts")?.count == 500)
    model.hide(chatId: 153, seq: 999)
    model.toggle(chatId: 153, seq: 999, service: service)
    #expect(service.calls.count == 1 && model.state(chatId: 153, seq: 999) == .text("新结果"))
  }

  @Test func hiddenPersistenceUsesTheSameKeysAsDiskCache() {
    let (name, defaults) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(["1:1": "保留但收起"], forKey: "voiceTranscripts")
    defaults.set(true, forKey: VoiceTranscripts.autoKey)
    let model = VoiceTranscripts(defaults: defaults)
    for seq in 1...501 { model.hide(chatId: 999, seq: Int64(seq)) }
    model.hide(chatId: 1, seq: 1)
    #expect(defaults.stringArray(forKey: "hiddenVoiceTranscripts") == ["1:1"])
    let restored = VoiceTranscripts(defaults: defaults); let service = TranscriptReplies()
    restored.autoTranscribe(chatId: 1, seq: 1, service: service)
    #expect(restored.state(chatId: 1, seq: 1) == nil && service.calls.isEmpty)
  }
}
