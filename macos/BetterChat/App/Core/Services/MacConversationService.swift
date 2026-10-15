import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacConversationService {
  func observe(_ receive: @escaping @MainActor ([DialogItem]) -> Void) async throws
  func refresh() async throws
  func setPinned(chatID: Int64, pinned: Bool) async throws
  func markRead(chatID: Int64, sequence: Int64) async throws
  func setPolicy(chatID: Int64, policy: String) async throws
}

@MainActor
struct MacSessionConversationService: MacConversationService {
  let session: Session

  func observe(_ receive: @escaping @MainActor ([DialogItem]) -> Void) async throws {
    for try await items in session.store.observeDialogs(limit: 5000) {
      try Task.checkCancellation()
      receive(items)
    }
  }
  func refresh() async throws {
    try await session.sync.catchUp()
    await session.sync.prefetch()
  }
  func setPinned(chatID: Int64, pinned: Bool) async throws {
    var request = Qqbridge_V1_SetPinnedRequest()
    request.chatID = chatID
    request.pinned = pinned
    _ = try await session.api.dialogs.setPinned(request: request, headers: session.api.headers).get()
  }
  func markRead(chatID: Int64, sequence: Int64) async throws {
    _ = try await session.api.markRead(chatId: chatID, maxSeq: sequence)
  }
  func setPolicy(chatID: Int64, policy: String) async throws {
    var request = Qqbridge_V1_SetNotifyPolicyRequest()
    request.chatID = chatID
    request.policy = policy
    _ = try await session.api.dialogs.setNotifyPolicy(request: request, headers: session.api.headers).get()
  }
}
