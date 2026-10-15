import Foundation
import QQBridgeKit
import QQBridgeProto

struct MacStorageChat: Identifiable, Sendable {
  let id: Int64
  let bytes: Int64
  let count: Int
  let scene: Qqbridge_V1_Scene
  let peerID: Int64
}

@MainActor
struct MacStorageSummaryService {
  let session: Session

  func chats(source: StorageChatsView.Source, group: StorageGroup, allMedia: Bool) async throws -> [MacStorageChat] {
    switch source {
    case .local:
      let store = session.store, kinds = group.localKinds, messages = group == .message
      return try await Task.detached(priority: .utility) {
        let rows = try messages ? store.messageUsage().byChat : store.cacheChats(kinds: kinds)
        return rows.map { MacStorageChat(id: $0.chatId, bytes: $0.bytes, count: $0.count, scene: .unspecified, peerID: 0) }
      }.value
    case .server:
      var request = Qqbridge_V1_ListStorageChatsRequest()
      request.categories = allMedia
        ? StorageGroup.allCases.filter { $0 != .message }.flatMap(\.serverCategories) : group.serverCategories
      request.limit = 200
      let response = try await session.api.media.listStorageChats(request: request, headers: session.api.headers).get()
      return response.chats.map {
        MacStorageChat(id: $0.chatID, bytes: Int64(clamping: $0.bytes), count: Int($0.count), scene: $0.scene, peerID: $0.peerID)
      }
    }
  }

  func detail(chatID: Int64) async throws -> Qqbridge_V1_GetChatStorageResponse {
    var request = Qqbridge_V1_GetChatStorageRequest()
    request.chatID = chatID
    return try await session.api.media.getChatStorage(request: request, headers: session.api.headers).get()
  }
}
