import Foundation
import QQBridgeProto
import Testing
@testable import QQBridgeKit

private actor IdentitySendingAPI: MessageSendingAPI {
  let store: LocalStore
  private(set) var requests: [Qqbridge_V1_SendMessageRequest] = []
  private(set) var originalTimes: [Int64] = []
  init(store: LocalStore) { self.store = store }
  func sendMessage(_ request: Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry {
    requests.append(request)
    originalTimes.append(try store.outboxEntry(clientRandomId: request.clientRandomID)?.createdAt ?? 0)
    throw CancellationError()
  }
}

struct SenderIdentityTests {
  private func entry(state: Qqbridge_V1_OutboxState = .failed) -> Qqbridge_V1_OutboxEntry {
    var result = Qqbridge_V1_OutboxEntry()
    result.clientRandomID = 123
    result.chatID = 1
    result.createdAt = 1234567
    result.state = state
    result.replyToSeq = 42
    var segment = Qqbridge_V1_OutgoingSegment()
    segment.image.sha256 = "test-sha"
    result.segments = [segment]
    return result
  }

  @Test func sendWithExistingIdPreservesOriginalTimeOnFailure() async throws {
    let store = try LocalStore.inMemory()
    let original = entry()
    try store.upsertLocalOutbox(original)
    let api = IdentitySendingAPI(store: store)
    let sender = Sender(api: api, store: store)
    await #expect(throws: CancellationError.self) {
      try await sender.send(chatId: 1, segments: original.segments, replyToSeq: 42, clientRandomId: 123)
    }
    #expect(await api.originalTimes == [original.createdAt])
    let saved = try #require(try store.outboxEntry(clientRandomId: 123))
    #expect(saved.createdAt == original.createdAt && saved.segments == original.segments)
    #expect(saved.state == .failed)
  }

  @Test func knownSentMessageReturnsWithoutNetworkOrLocalDowngrade() async throws {
    let store = try LocalStore.inMemory()
    var original = entry(state: .sent)
    original.pts = 9
    try store.upsertLocalOutbox(original)
    let api = IdentitySendingAPI(store: store)
    let sender = Sender(api: api, store: store)
    let result = try await sender.send(chatId: 1, segments: original.segments, replyToSeq: 42, clientRandomId: 123)
    #expect(result == original)
    #expect(await api.requests.isEmpty)
    #expect(try store.outboxEntry(clientRandomId: 123) == original)
  }

  @Test func reusedIdRejectsChangedChatContentOrReply() async throws {
    let store = try LocalStore.inMemory()
    let original = entry()
    try store.upsertLocalOutbox(original)
    let api = IdentitySendingAPI(store: store)
    let sender = Sender(api: api, store: store)
    for choice in 0..<3 {
      await #expect(throws: APIError.self) {
        try await sender.send(chatId: choice == 0 ? 2 : 1,
          segments: choice == 1 ? [] : original.segments,
          replyToSeq: choice == 2 ? 99 : 42, clientRandomId: 123)
      }
    }
    #expect(await api.requests.isEmpty)
    #expect(try store.outboxEntry(clientRandomId: 123) == original)
  }

  @Test(arguments: [Qqbridge_V1_OutboxState.pending, .sending])
  func serverAcceptedMessageDoesNotStartAnotherLocalAttempt(state: Qqbridge_V1_OutboxState) async throws {
    let store = try LocalStore.inMemory()
    var original = entry(state: state)
    original.pts = 9
    try store.upsertLocalOutbox(original)
    let api = IdentitySendingAPI(store: store)
    let sender = Sender(api: api, store: store)
    let result = try await sender.send(chatId: 1, segments: original.segments, replyToSeq: 42, clientRandomId: 123)
    #expect(result == original)
    #expect(await api.requests.isEmpty)
    #expect(try store.outboxEntry(clientRandomId: 123) == original)
  }
}
