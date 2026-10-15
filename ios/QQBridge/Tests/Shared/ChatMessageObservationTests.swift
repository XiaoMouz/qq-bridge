import Foundation
import QQBridgeKit
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor
private final class MessageObservationReplies: ChatMessageObservationService {
  private(set) var limits: [Int] = []
  private var callbacks: [Int: @MainActor ([ChatItem]) -> Void] = [:]
  private var endings: [Int: CheckedContinuation<Void, any Error>] = [:]

  func observe(limit: Int, receive: @escaping @MainActor ([ChatItem]) -> Void) async throws {
    let index = limits.count
    limits.append(limit)
    callbacks[index] = receive
    try await withCheckedThrowingContinuation { endings[index] = $0 }
  }
  func emit(_ index: Int, seq: Int64) {
    var message = Qqbridge_V1_Message()
    message.chatID = 153; message.seq = seq
    callbacks[index]?([.message(message)])
  }
  func finish(_ index: Int, failing: Bool) {
    if failing { endings.removeValue(forKey: index)?.resume(throwing: URLError(.cannotOpenFile)) }
    else { endings.removeValue(forKey: index)?.resume() }
  }
  func wait(_ count: Int) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while limits.count < count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(limits.count == count)
  }
}

@Suite(.serialized) @MainActor
struct ChatMessageObservationTests {
  @Test func failureKeepsVisibleItemsAndRetryResumesAtTheSameLimit() async {
    let service = MessageObservationReplies(), model = ChatMessageObservation()
    var visible: [ChatItem] = []
    let initial = Task { await model.observe(limit: 180, using: service) { visible = $0 } }
    await service.wait(1)
    service.emit(0, seq: 1)
    let firstItems = visible
    service.finish(0, failing: true)
    await initial.value
    #expect(!visible.isEmpty && visible == firstItems && model.error != nil)
    let previous = model.retry
    model.restart()
    #expect(model.retry != previous && model.error == nil)
    let retry = Task { await model.observe(limit: 180, using: service) { visible = $0 } }
    await service.wait(2)
    service.emit(1, seq: 2)
    #expect(visible.last?.id == "m2" && service.limits == [180, 180])
    model.cancel(); retry.cancel(); service.finish(1, failing: true)
    await retry.value
    #expect(model.error == nil)
  }

  @Test(arguments: [false, true]) func supersededSubscriptionCannotReplaceNewItemsOrPublishError(failing: Bool) async {
    let service = MessageObservationReplies(), model = ChatMessageObservation()
    var visible: [ChatItem] = []
    let old = Task { await model.observe(limit: 60, using: service) { visible = $0 } }
    await service.wait(1)
    model.restart()
    let fresh = Task { await model.observe(limit: 120, using: service) { visible = $0 } }
    await service.wait(2)
    service.emit(1, seq: 20)
    let current = visible
    service.emit(0, seq: 10)
    service.finish(0, failing: failing)
    await old.value
    #expect(visible == current && model.error == nil)
    model.cancel(); fresh.cancel(); service.finish(1, failing: false)
    await fresh.value
    #expect(model.error == nil)
  }

  @Test func leavingPageRejectsLateDeliveryBeforeSwiftUICancelsTask() async {
    let service = MessageObservationReplies(), model = ChatMessageObservation()
    var received = 0
    let task = Task { await model.observe(limit: 60, using: service) { _ in received += 1 } }
    await service.wait(1)
    model.cancel()
    service.emit(0, seq: 1)
    service.finish(0, failing: true)
    await task.value
    #expect(received == 0 && model.error == nil)
  }

  @Test func unexpectedNormalCompletionIsRecoverableFailure() async {
    let service = MessageObservationReplies(), model = ChatMessageObservation()
    let task = Task { await model.observe(limit: 60, using: service) { _ in } }
    await service.wait(1)
    service.finish(0, failing: false)
    await task.value
    #expect(model.error == "消息列表已停止更新，请重试")
    model.restart()
    #expect(model.error == nil)
  }
}
