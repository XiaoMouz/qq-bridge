import Foundation
import QQBridgeProto
import Testing

@testable import QQBridgeKit

/// 模拟不响应任务取消、仍会返回数据的传输层；由测试明确决定何时放行，不靠 sleep 猜时序。
private actor DelayedSyncResponse<Value: Sendable> {
  private var pending: CheckedContinuation<Value, Never>?
  private var requested: [CheckedContinuation<Void, Never>] = []

  func response() async -> Value {
    await withCheckedContinuation { continuation in
      pending = continuation
      requested.forEach { $0.resume() }
      requested.removeAll()
    }
  }

  func waitUntilRequested() async {
    if pending != nil { return }
    await withCheckedContinuation { requested.append($0) }
  }

  func complete(_ value: Value) {
    pending?.resume(returning: value)
    pending = nil
  }
}

struct SyncCancellationTests {
  @Test(arguments: [false, true])
  func cancelledGlobalDifferenceCannotOverwriteOrResetNewerState(tooLong: Bool) async throws {
    let store = try LocalStore.inMemory()
    try store.apply(difference: difference(pts: 10, dialogs: [dialog(1)]))
    let server = FakeServer()
    let delayed = DelayedSyncResponse<Qqbridge_V1_Difference>()
    server.differenceOverride = { _ in await delayed.response() }
    let engine = SyncEngine(api: server, store: store)
    let oldRequest = Task { try await engine.catchUp() }
    await delayed.waitUntilRequested()
    oldRequest.cancel()
    try store.apply(difference: difference(pts: 20, dialogs: [dialog(2)]))
    var old = difference(pts: 11, dialogs: [dialog(3)])
    old.tooLong = tooLong
    await delayed.complete(old)
    do {
      try await oldRequest.value
      Issue.record("取消后的旧差量应返回 CancellationError")
    } catch is CancellationError {} catch { Issue.record("错误类型不符：\(error)") }
    #expect(try store.pts() == 20)
    #expect(try store.dialog(chatId: 2) != nil)
    #expect(try store.dialog(chatId: 3) == nil)
  }

  @Test func cancelledChatDifferenceCannotResetNewerMessages() async throws {
    let store = try LocalStore.inMemory()
    try store.applyChat(chatId: 1, messages: [message(1, 1)], events: [], newChatPts: 1)
    let server = FakeServer()
    let delayed = DelayedSyncResponse<Qqbridge_V1_GetChatDifferenceResponse>()
    server.chatDifferenceOverride = { await delayed.response() }
    let engine = SyncEngine(api: server, store: store)
    let oldRequest = Task { try await engine.catchUpChat(1) }
    await delayed.waitUntilRequested()
    oldRequest.cancel()
    try store.applyChat(chatId: 1, messages: [message(1, 20)], events: [], newChatPts: 20)
    await delayed.complete(chatPage(chatPts: 12, [message(1, 12)], tooLong: true))
    do {
      try await oldRequest.value
      Issue.record("取消后的旧会话差量应返回 CancellationError")
    } catch is CancellationError {} catch { Issue.record("错误类型不符：\(error)") }
    #expect(try store.chatState(chatId: 1).chatPts == 20)
    #expect(try store.messages(chatId: 1).map(\.seq).sorted() == [1, 20])
  }

  @Test func cancelledPrefetchCannotResetNewerMessages() async throws {
    let store = try LocalStore.inMemory()
    try store.apply(difference: difference(pts: 1, dialogs: [dialog(1, chatPts: 12)]))
    try store.applyChat(chatId: 1, messages: [message(1, 1)], events: [], newChatPts: 1)
    let server = FakeServer()
    let delayed = DelayedSyncResponse<[Qqbridge_V1_ChatDifferenceResult]>()
    server.prefetchOverride = { await delayed.response() }
    let engine = SyncEngine(api: server, store: store)
    let oldRequest = Task { await engine.prefetch() }
    await delayed.waitUntilRequested()
    oldRequest.cancel()
    try store.applyChat(chatId: 1, messages: [message(1, 20)], events: [], newChatPts: 20)
    var old = Qqbridge_V1_ChatDifferenceResult()
    old.chatID = 1
    old.chatPts = 12
    old.tooLong = true
    old.isFinal = true
    old.messages = [message(1, 12)]
    await delayed.complete([old])
    await oldRequest.value
    #expect(try store.chatState(chatId: 1).chatPts == 20)
    #expect(try store.messages(chatId: 1).map(\.seq).sorted() == [1, 20])
  }
}

struct ChatCatchUpRaceTests {
  @Test func liveMessageDuringFirstScreenIsRecoveredBeforeOpenCompletes() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    let delayed = DelayedSyncResponse<Qqbridge_V1_GetChatDifferenceResponse>()
    let responses = ChatRaceResponses(delayed: delayed)
    server.chatDifferenceOverride = { await responses.next() }
    var options = SyncEngine.Options()
    options.prefetchChats = 0
    let engine = SyncEngine(api: server, store: store, options: options)
    await engine.start()
    try await eventually { server.callLog.contains("subscribe:0") }
    let opening = Task { try await engine.openChat(1) }
    await delayed.waitUntilRequested()
    var update = Qqbridge_V1_ChatMessageUpdate()
    update.chatID = 1; update.chatPts = 20; update.message = message(1, 20)
    server.push(.chatMessage(update))
    // 后续全局事件落库是流已消费前面消息的屏障。
    var marker = Qqbridge_V1_DialogUpdate()
    marker.pts = 1; marker.dialog = dialog(2)
    server.push(.dialog(marker))
    try await eventually { try store.pts() == 1 }
    await delayed.complete(chatPage(chatPts: 10, [message(1, 10)]))
    try await opening.value
    await engine.stop()
    #expect(try store.chatState(chatId: 1).chatPts == 20)
    #expect(server.callLog.contains("chat:1:10"))
    #expect(try store.messages(chatId: 1).map(\.seq) == [10, 20])
  }

  @Test func subscribeDifferenceRepairsLoadedChatOutsidePrefetchLimit() async throws {
    let store = try LocalStore.inMemory()
    try store.applyChat(chatId: 1, messages: [message(1, 10)], events: [], newChatPts: 10)
    let server = FakeServer()
    server.chatPages["1:10"] = chatPage(chatPts: 20, [message(1, 20)])
    var options = SyncEngine.Options()
    options.prefetchChats = 0
    let engine = SyncEngine(api: server, store: store, options: options)
    await engine.start()
    try await eventually { server.callLog.contains("subscribe:0") }
    server.push(.difference(difference(pts: 1, dialogs: [dialog(1, chatPts: 20)])))
    var marker = Qqbridge_V1_DialogUpdate()
    marker.pts = 2; marker.dialog = dialog(2)
    server.push(.dialog(marker))
    try await eventually { try store.pts() == 2 }
    await engine.stop()
    #expect(try store.messages(chatId: 1).map(\.seq) == [10, 20])
  }

  @Test func openingUncachedChatFollowsNonFinalFirstPage() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    server.chatPages["1:0"] = chatPage(chatPts: 50, (1...50).map { message(1, $0) }, final: false)
    server.chatPages["1:50"] = chatPage(chatPts: 75, (51...75).map { message(1, $0) })
    let engine = SyncEngine(api: server, store: store)
    try await engine.openChat(1)
    #expect(try store.chatState(chatId: 1).chatPts == 75)
    #expect(try store.messages(chatId: 1).last?.seq == 75)
    #expect(server.callLog == ["chat:1:0", "chat:1:50"])
  }

  @Test func prefetchFollowsNonFinalPage() async throws {
    let store = try LocalStore.inMemory()
    try store.apply(difference: difference(pts: 1, dialogs: [dialog(1, chatPts: 75)]))
    let server = FakeServer()
    server.chatPages["1:0"] = chatPage(chatPts: 50, (1...50).map { message(1, $0) }, final: false)
    server.chatPages["1:50"] = chatPage(chatPts: 75, (51...75).map { message(1, $0) })
    let engine = SyncEngine(api: server, store: store)
    await engine.prefetch()
    #expect(try store.chatState(chatId: 1).chatPts == 75)
    #expect(try store.messages(chatId: 1).last?.seq == 75)
  }

  @Test func prefetchRebasesWhenConcurrentOpenIsStillBehindBatchResponse() async throws {
    let store = try LocalStore.inMemory()
    try store.apply(difference: difference(pts: 1, dialogs: [dialog(1, chatPts: 30)]))
    try store.applyChat(chatId: 1, messages: [message(1, 1)], events: [], newChatPts: 1)
    let server = FakeServer()
    let delayed = DelayedSyncResponse<[Qqbridge_V1_ChatDifferenceResult]>()
    server.prefetchOverride = { await delayed.response() }
    server.chatPages["1:1"] = chatPage(chatPts: 20, [message(1, 20)])
    server.chatPages["1:20"] = chatPage(chatPts: 30, [message(1, 30)])
    let engine = SyncEngine(api: server, store: store)
    let prefetch = Task { await engine.prefetch() }
    await delayed.waitUntilRequested()
    try await engine.openChat(1)
    var newer = Qqbridge_V1_ChatDifferenceResult()
    newer.chatID = 1
    newer.chatPts = 30
    newer.tooLong = true
    newer.isFinal = true
    newer.messages = [message(1, 30)]
    await delayed.complete([newer])
    await prefetch.value
    #expect(try store.chatState(chatId: 1).chatPts == 30)
    #expect(try store.messages(chatId: 1).map(\.seq) == [1, 20, 30])
    #expect(server.callLog.contains("chat:1:20"))
  }

  @Test func latePrefetchResetCannotEraseMessagesLoadedWhileOpeningChat() async throws {
    let store = try LocalStore.inMemory()
    try store.apply(difference: difference(pts: 1, dialogs: [dialog(1, chatPts: 12)]))
    try store.applyChat(chatId: 1, messages: [message(1, 1)], events: [], newChatPts: 1, contiguous: SeqRange(1, 1))
    let server = FakeServer()
    let delayed = DelayedSyncResponse<[Qqbridge_V1_ChatDifferenceResult]>()
    server.prefetchOverride = { await delayed.response() }
    server.chatPages["1:1"] = chatPage(chatPts: 20, [message(1, 20)])
    let engine = SyncEngine(api: server, store: store)
    let prefetch = Task { await engine.prefetch() }
    await delayed.waitUntilRequested()
    try await engine.openChat(1)
    var old = Qqbridge_V1_ChatDifferenceResult()
    old.chatID = 1
    old.chatPts = 12
    old.tooLong = true
    old.isFinal = true
    old.messages = [message(1, 12)]
    await delayed.complete([old])
    await prefetch.value
    #expect(try store.chatState(chatId: 1).chatPts == 20)
    #expect(try store.messages(chatId: 1).map(\.seq) == [1, 20])
  }

  @Test func lateChatResetCannotEraseNewerPrefetch() async throws {
    let store = try LocalStore.inMemory()
    try store.apply(difference: difference(pts: 1, dialogs: [dialog(1, chatPts: 20)]))
    try store.applyChat(chatId: 1, messages: [message(1, 1)], events: [], newChatPts: 1)
    let server = FakeServer()
    let delayed = DelayedSyncResponse<Qqbridge_V1_GetChatDifferenceResponse>()
    let responses = ChatRaceResponses(delayed: delayed)
    server.chatDifferenceOverride = { await responses.next() }
    server.chatPages["1:1"] = chatPage(chatPts: 20, [message(1, 20)], tooLong: true)
    let engine = SyncEngine(api: server, store: store)
    let opening = Task { try await engine.openChat(1) }
    await delayed.waitUntilRequested()
    await engine.prefetch()
    await delayed.complete(chatPage(chatPts: 12, [message(1, 12)], tooLong: true))
    try await opening.value
    #expect(try store.chatState(chatId: 1).chatPts == 20)
    #expect(try store.messages(chatId: 1).map(\.seq) == [20])
  }
}

private actor ChatRaceResponses {
  let delayed: DelayedSyncResponse<Qqbridge_V1_GetChatDifferenceResponse>
  var first = true
  init(delayed: DelayedSyncResponse<Qqbridge_V1_GetChatDifferenceResponse>) { self.delayed = delayed }
  func next() async -> Qqbridge_V1_GetChatDifferenceResponse {
    if first {
      first = false
      return await delayed.response()
    }
    return chatPage(chatPts: 20, [message(1, 20)])
  }
}
