import Foundation
import QQBridgeProto
import Testing

@testable import QQBridgeKit

private actor ScriptedSendingAPI: MessageSendingAPI {
  private(set) var requests: [Qqbridge_V1_SendMessageRequest] = []
  let respond: @Sendable (Int, Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry
  init(_ respond: @escaping @Sendable (Int, Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry) {
    self.respond = respond
  }
  func sendMessage(_ request: Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry {
    requests.append(request)
    return try await respond(requests.count, request)
  }
}

private actor SendingGate {
  private var pending: CheckedContinuation<Qqbridge_V1_OutboxEntry, any Error>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  func wait() async throws -> Qqbridge_V1_OutboxEntry {
    try await withCheckedThrowingContinuation {
      pending = $0
      observers.forEach { $0.resume() }
      observers.removeAll()
    }
  }
  func waitUntilRequested() async {
    if pending != nil { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func fail() {
    pending?.resume(throwing: APIError(code: .unavailable, message: "测试断网"))
    pending = nil
  }
}

private func outgoing(_ id: Int64, state: Qqbridge_V1_OutboxState, pts: Int64 = 0) -> Qqbridge_V1_OutboxEntry {
  var entry = Qqbridge_V1_OutboxEntry()
  entry.clientRandomID = id
  entry.chatID = 153
  entry.state = state
  entry.pts = pts
  entry.createdAt = 1_700_000_000
  entry.replyToSeq = 42
  var text = Qqbridge_V1_OutgoingSegment()
  text.text = "隔离发送测试，不连接真实服务"
  entry.segments = [text]
  return entry
}

struct SenderRecoveryTests {
  @Test func cancellingDuringNetworkRetryFinishesLocalPendingState() async throws {
    let store = try LocalStore.inMemory()
    let gate = SendingGate()
    let api = ScriptedSendingAPI { _, _ in try await gate.wait() }
    let sender = Sender(api: api, store: store)
    let task = Task { try await sender.send(chatId: 153, segments: outgoing(1, state: .pending).segments, clientRandomId: 1) }
    await gate.waitUntilRequested()
    task.cancel()
    await gate.fail()
    await #expect(throws: CancellationError.self) { try await task.value }
    let saved = try #require(store.outbox(chatId: 153).first)
    #expect(saved.state == .failed)
    #expect(!saved.error.isEmpty)
    #expect(await api.requests.count == 1)
  }

  @Test func manualRetryAfterLostAcknowledgementKeepsIdempotencyKey() async throws {
    let store = try LocalStore.inMemory()
    // 前四次模拟服务端已收下但回包丢失；第五次为用户手动重试，服务端按 ID 返回已发送条目。
    let api = ScriptedSendingAPI { attempt, request in
      if attempt <= 4 { throw APIError(code: .unavailable, message: "回包丢失") }
      return outgoing(request.clientRandomID, state: .sent, pts: 9)
    }
    let sender = Sender(api: api, store: store)
    let original = outgoing(88, state: .pending)
    await #expect(throws: APIError.self) {
      try await sender.send(chatId: original.chatID, segments: original.segments, replyToSeq: original.replyToSeq, clientRandomId: 88)
    }
    let failed = try #require(store.outbox(chatId: 153).first)
    #expect(failed.state == .failed)
    let acknowledged = try await sender.resend(failed)
    #expect(acknowledged.clientRandomID == 88)
    #expect(await api.requests.map(\.clientRandomID) == [88, 88, 88, 88, 88])
    #expect(await api.requests.allSatisfy { $0.replyToSeq == 42 && $0.segments == original.segments })
    #expect(try store.outbox(chatId: 153).map(\.clientRandomID) == [88])
  }

  @Test func retryOfServerFailurePreservesOriginalEntryAndPayload() async throws {
    let store = try LocalStore.inMemory()
    let original = outgoing(99, state: .failed, pts: 10)
    try store.upsertLocalOutbox(original)
    let api = ScriptedSendingAPI { _, request in
      let local = try #require(store.outbox(chatId: 153).first)
      #expect(local.clientRandomID == original.clientRandomID)
      #expect(local.createdAt == original.createdAt)
      #expect(local.pts == original.pts)
      #expect(local.state == .pending)
      return outgoing(request.clientRandomID, state: .pending, pts: 11)
    }
    let returned = try await Sender(api: api, store: store).resend(original)
    #expect(returned.clientRandomID == 99)
    #expect(await api.requests.first?.replyToSeq == 42)
    #expect(try store.outbox(chatId: 153).count == 1)
  }

  @Test(arguments: [false, true])
  func lateRPCResultCannotReplaceNewerSubscribedState(fails: Bool) async throws {
    let store = try LocalStore.inMemory()
    let api = ScriptedSendingAPI { _, request in
      // Subscribe 已先确认 sent，随后较旧的 RPC 回包/错误才到达。
      try store.apply(outbox: outgoing(request.clientRandomID, state: .sent, pts: 20), pts: 20)
      if fails { throw APIError(code: .permissionDenied, message: "迟到错误") }
      return outgoing(request.clientRandomID, state: .pending, pts: 10)
    }
    let sender = Sender(api: api, store: store)
    do { _ = try await sender.send(chatId: 153, segments: outgoing(5, state: .pending).segments, clientRandomId: 5) }
    catch { #expect(fails) }
    let saved = try #require(store.outbox(chatId: 153).first)
    #expect(saved.state == .sent)
    #expect(saved.pts == 20)
  }
}
