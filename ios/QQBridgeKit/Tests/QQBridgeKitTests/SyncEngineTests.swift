import Foundation
import QQBridgeProto
import Testing

@testable import QQBridgeKit

/// 假服务端：按脚本返回差量，记录调用；Subscribe 的内容由测试推进去。
final class FakeServer: SyncAPI, @unchecked Sendable {
  private let lock = NSLock()
  var differencePages: [Int64: Qqbridge_V1_Difference] = [:]  // 按请求的 pts 返回
  var chatPages: [String: Qqbridge_V1_GetChatDifferenceResponse] = [:]  // "chatId:chatPts"
  var history: [String: Qqbridge_V1_GetHistoryResponse] = [:]  // "chatId:beforeSeq"
  var calls: [String] = []
  var stateError: APIError?
  private var subscribers: [AsyncThrowingStream<Qqbridge_V1_SubscribeResponse, any Error>.Continuation] = []

  private func record(_ call: String) {
    lock.withLock { calls.append(call) }
  }

  func getState() async throws -> Qqbridge_V1_GetStateResponse { .init() }

  func getDifference(pts: Int64, limit: UInt32) async throws -> Qqbridge_V1_Difference {
    record("diff:\(pts)")
    if let error = lock.withLock({ stateError }) { throw error }
    return lock.withLock { differencePages[pts] } ?? { var d = Qqbridge_V1_Difference(); d.pts = pts; d.isFinal = true; return d }()
  }

  func getChatDifference(chatId: Int64, chatPts: Int64, limit: UInt32) async throws -> Qqbridge_V1_GetChatDifferenceResponse {
    record("chat:\(chatId):\(chatPts)")
    return lock.withLock { chatPages["\(chatId):\(chatPts)"] } ?? { var r = Qqbridge_V1_GetChatDifferenceResponse(); r.chatPts = chatPts; r.isFinal = true; return r }()
  }

  func getChatDifferences(_ chats: [(chatId: Int64, chatPts: Int64)], perChatLimit: UInt32) async throws -> [Qqbridge_V1_ChatDifferenceResult] {
    record("chats:" + chats.map { "\($0.chatId)@\($0.chatPts)" }.joined(separator: ","))
    return chats.compactMap { c in
      guard let page = lock.withLock({ chatPages["\(c.chatId):\(c.chatPts)"] }) else { return nil }
      var r = Qqbridge_V1_ChatDifferenceResult()
      r.chatID = c.chatId
      r.chatPts = page.chatPts
      r.isFinal = page.isFinal
      r.tooLong = page.tooLong
      r.messages = page.messages
      return r
    }
  }

  func getHistory(chatId: Int64, beforeSeq: Int64?, limit: UInt32) async throws -> Qqbridge_V1_GetHistoryResponse {
    record("history:\(chatId):\(beforeSeq.map(String.init) ?? "-")")
    return lock.withLock { history["\(chatId):\(beforeSeq.map(String.init) ?? "-")"] } ?? .init()
  }

  func subscribe(pts: Int64) -> AsyncThrowingStream<Qqbridge_V1_SubscribeResponse, any Error> {
    record("subscribe:\(pts)")
    let (stream, continuation) = AsyncThrowingStream<Qqbridge_V1_SubscribeResponse, any Error>.makeStream()
    lock.withLock { subscribers.append(continuation) }
    return stream
  }

  func push(_ event: Qqbridge_V1_SubscribeResponse.OneOf_Event) {
    var r = Qqbridge_V1_SubscribeResponse()
    r.event = event
    for s in lock.withLock({ subscribers }) { s.yield(r) }
  }

  func closeStreams(error: (any Error)? = nil) {
    for s in lock.withLock({ subscribers }) { s.finish(throwing: error) }
  }

  var callLog: [String] { lock.withLock { calls } }
}

func dialog(_ chatId: Int64, pts: Int64 = 0, chatPts: Int64 = 0, topTime: Int64 = 0, pinned: Bool = false) -> Qqbridge_V1_Dialog {
  var d = Qqbridge_V1_Dialog()
  d.chatID = chatId
  d.dialogPts = pts
  d.chatPts = chatPts
  d.topTime = topTime
  d.pinned = pinned
  d.scene = .group
  d.peerID = chatId * 10
  return d
}

func message(_ chatId: Int64, _ seq: Int64, version: Int64 = 1, text: String? = nil) -> Qqbridge_V1_Message {
  var m = Qqbridge_V1_Message()
  m.chatID = chatId
  m.seq = seq
  m.version = version
  m.time = 1_700_000_000 + seq
  m.text = text ?? "m\(seq)"
  return m
}

func difference(pts: Int64, final: Bool = true, dialogs: [Qqbridge_V1_Dialog] = []) -> Qqbridge_V1_Difference {
  var d = Qqbridge_V1_Difference()
  d.pts = pts
  d.isFinal = final
  d.dialogs = dialogs
  return d
}

func chatPage(chatPts: Int64, _ messages: [Qqbridge_V1_Message], final: Bool = true, tooLong: Bool = false) -> Qqbridge_V1_GetChatDifferenceResponse {
  var r = Qqbridge_V1_GetChatDifferenceResponse()
  r.chatPts = chatPts
  r.messages = messages
  r.isFinal = final
  r.tooLong = tooLong
  return r
}

/// 轮询等待条件成立（同步引擎在后台任务里处理推送）。
func eventually(_ condition: () throws -> Bool) async throws {
  for _ in 0..<200 {
    if try condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try condition(), "condition not met in time")
}

@Suite struct SyncEngineTests {
  var options: SyncEngine.Options {
    var o = SyncEngine.Options()
    o.gapWait = .milliseconds(10)
    o.prefetchChats = 0
    return o
  }

  @Test func catchUpFollowsPagesAndStartsOverWhenTooLong() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    server.differencePages[0] = difference(pts: 5, final: false, dialogs: [dialog(1, topTime: 10)])
    server.differencePages[5] = difference(pts: 9, dialogs: [dialog(2, topTime: 20, pinned: true)])
    let engine = SyncEngine(api: server, store: store, options: options)
    try await engine.catchUp()
    #expect(try store.pts() == 9)
    #expect(try store.dialogs().map(\.chatID) == [2, 1])  // 置顶在前

    // 游标太旧：清空后从 0 重拉。
    var tooLong = Qqbridge_V1_Difference()
    tooLong.tooLong = true
    server.differencePages[9] = tooLong
    server.differencePages[0] = difference(pts: 12, dialogs: [dialog(3, topTime: 5)])
    try await engine.catchUp()
    #expect(try store.pts() == 12)
    #expect(try store.dialogs().map(\.chatID) == [3])
  }

  @Test func appliesLiveUpdatesInOrderAndFillsGapsWithADifference() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    server.differencePages[0] = difference(pts: 10, dialogs: [dialog(1, topTime: 1)])
    let engine = SyncEngine(api: server, store: store, options: options)
    await engine.start()
    try await eventually { server.callLog.contains("subscribe:10") }

    var u = Qqbridge_V1_DialogUpdate()
    u.pts = 11
    u.dialog = dialog(1, topTime: 2)
    server.push(.dialog(u))
    try await eventually { try store.pts() == 11 }

    u.pts = 11  // 重复：忽略
    u.dialog = dialog(1, topTime: 99)
    server.push(.dialog(u))

    // 跳号：等一下再用差量补齐。
    server.differencePages[11] = difference(pts: 14, dialogs: [dialog(4, topTime: 3)])
    u.pts = 14
    u.dialog = dialog(4, topTime: 3)
    server.push(.dialog(u))
    try await eventually { try store.pts() == 14 }
    #expect(server.callLog.contains("diff:11"))
    #expect(try store.dialog(chatId: 1)?.topTime == 2)
    await engine.stop()
  }

  @Test func tracksMessagesOnlyForLoadedChatsAndFillsChatGaps() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    server.differencePages[0] = difference(pts: 1, dialogs: [dialog(7, chatPts: 30)])
    server.chatPages["7:0"] = chatPage(chatPts: 30, [message(7, 101), message(7, 102), message(7, 103)])
    let engine = SyncEngine(api: server, store: store, options: options)
    await engine.start()
    try await eventually { server.callLog.contains("subscribe:1") }

    // 没打开过的会话：消息更新不落库。
    var u = Qqbridge_V1_ChatMessageUpdate()
    u.chatID = 8
    u.chatPts = 1
    u.message = message(8, 1)
    server.push(.chatMessage(u))

    try await engine.openChat(7)
    #expect(try store.chatState(chatId: 7) == ChatState(chatPts: 30, loadedRanges: [SeqRange(101, 103)]))

    u.chatID = 7
    u.chatPts = 31
    u.message = message(7, 104)
    server.push(.chatMessage(u))
    try await eventually { try store.chatState(chatId: 7).chatPts == 31 }
    #expect(try store.chatState(chatId: 7).loadedRanges == [SeqRange(101, 104)])  // 新消息顺延已加载区间

    // 跳号：拉该会话的差量。
    server.chatPages["7:31"] = chatPage(chatPts: 33, [message(7, 105), message(7, 102, version: 32, text: "edited")])
    u.chatPts = 33
    u.message = message(7, 106)
    server.push(.chatMessage(u))
    try await eventually { try store.chatState(chatId: 7).chatPts == 33 }
    #expect(server.callLog.contains("chat:7:31"))
    #expect(try store.messages(chatId: 7).map(\.text) == ["m101", "edited", "m103", "m104", "m105"])
    #expect(try store.messages(chatId: 8).isEmpty)
    await engine.stop()
  }

  @Test func loadsOlderPagesAndMergesRanges() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    server.chatPages["5:0"] = chatPage(chatPts: 9, [message(5, 50), message(5, 51)])
    var page = Qqbridge_V1_GetHistoryResponse()
    page.messages = [message(5, 47), message(5, 49)]  // 48 在服务端也没有（缺口）
    server.history["5:50"] = page
    let engine = SyncEngine(api: server, store: store, options: options)
    try await engine.openChat(5)
    #expect(try await engine.loadOlder(5) == 2)
    #expect(try store.chatState(chatId: 5).loadedRanges == [SeqRange(47, 51)])
    #expect(try await engine.loadOlder(5) == 0)  // 到头
    #expect(server.callLog.contains("history:5:47"))
  }

  @Test func prefetchesOnlyChatsThatAreNewOrBehind() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    try store.apply(difference: difference(pts: 3, dialogs: [dialog(1, chatPts: 4, topTime: 3), dialog(2, chatPts: 2, topTime: 2), dialog(3, chatPts: 7, topTime: 1)]))
    try store.applyChat(chatId: 2, messages: [message(2, 1)], events: [], newChatPts: 2, contiguous: SeqRange(1, 1))
    try store.applyChat(chatId: 3, messages: [message(3, 1)], events: [], newChatPts: 5, contiguous: SeqRange(1, 1))
    server.chatPages["1:0"] = chatPage(chatPts: 4, [message(1, 9)])
    server.chatPages["3:5"] = chatPage(chatPts: 7, [message(3, 2)])
    var o = options
    o.prefetchChats = 10
    let engine = SyncEngine(api: server, store: store, options: o)
    await engine.prefetch()
    #expect(server.callLog == ["chats:1@0,3@5"])  // 会话 2 已是最新
    #expect(try store.chatState(chatId: 1).chatPts == 4)
    #expect(try store.chatState(chatId: 3).loadedRanges == [SeqRange(1, 1)])  // 增量不改区间
    #expect(try store.messages(chatId: 3).map(\.seq) == [1, 2])
  }

  @Test func stopsAndAsksForLoginWhenTheDeviceTokenIsRevoked() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    server.stateError = APIError(code: .unauthenticated, message: "revoked")
    let engine = SyncEngine(api: server, store: store, options: options)
    let events = await engine.events()
    await engine.start()
    var seen: [ConnectionState] = []
    for await e in events {
      if case .connection(let s) = e { seen.append(s) }
      if seen.last == .unauthenticated { break }
    }
    #expect(seen.contains(.unauthenticated))
  }

  @Test func reconnectsAfterTheStreamDrops() async throws {
    let store = try LocalStore.inMemory()
    let server = FakeServer()
    var o = options
    o.maxBackoff = 0.05
    let engine = SyncEngine(api: server, store: store, options: o)
    await engine.start()
    try await eventually { server.callLog.filter { $0.hasPrefix("subscribe") }.count == 1 }
    server.closeStreams(error: APIError(code: .unavailable, message: "network"))
    try await eventually { server.callLog.filter { $0.hasPrefix("subscribe") }.count == 2 }
    await engine.stop()
  }
}

@Suite struct LocalStoreTests {
  @Test func mergesRanges() {
    #expect(LocalStore.merge([SeqRange(1, 3), SeqRange(10, 12)], SeqRange(4, 9)) == [SeqRange(1, 12)])
    #expect(LocalStore.merge([SeqRange(5, 6)], SeqRange(1, 2)) == [SeqRange(1, 2), SeqRange(5, 6)])
  }

  @Test func olderVersionsNeverOverwriteNewerOnes() throws {
    let store = try LocalStore.inMemory()
    try store.applyChat(chatId: 1, messages: [message(1, 1, version: 5, text: "new")], events: [], newChatPts: 5)
    try store.applyChat(chatId: 1, messages: [message(1, 1, version: 3, text: "old")], events: [], newChatPts: nil)
    #expect(try store.messages(chatId: 1).map(\.text) == ["new"])
  }

  @Test func trimsOldMessagesButKeepsTheLatestScreen() throws {
    let store = try LocalStore.inMemory()
    let now = Date(timeIntervalSince1970: 1_700_000_000 + 400 * 86400)
    try store.applyChat(chatId: 1, messages: (1...120).map { message(1, $0) }, events: [], newChatPts: 1, contiguous: SeqRange(1, 120))
    let deleted = try store.trimMessages(keepPerChat: 100, keepDays: 30, now: now)
    #expect(deleted == 70)  // 全都超过 30 天：只留最新 50 条
    #expect(try store.chatState(chatId: 1).loadedRanges == [SeqRange(71, 120)])
  }
}
