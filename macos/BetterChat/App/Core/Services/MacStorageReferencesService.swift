import Foundation
import QQBridgeKit
import QQBridgeProto

struct MacStorageReference: Identifiable, Sendable {
  let id: Int64
  let scene: Qqbridge_V1_Scene
  let peerID: Int64
}

@MainActor protocol MacStorageReferencesService {
  func references() async throws -> [MacStorageReference]
}

struct MacSessionStorageReferencesService: MacStorageReferencesService {
  let session: Session
  let source: StorageChatsView.Source
  let sha256: String

  func references() async throws -> [MacStorageReference] {
    switch source {
    case .local:
      let store = session.store, sha256 = sha256
      return try await Task.detached(priority: .utility) {
        try store.chatsReferencing(sha256).map {
          MacStorageReference(id: $0.chatId, scene: .unspecified, peerID: 0)
        }
      }.value
    case .server:
      var request = Qqbridge_V1_ListMediaUsagesRequest()
      request.sha256 = sha256
      let response = try await session.api.media.listMediaUsages(request: request, headers: session.api.headers).get()
      return response.usages.map { MacStorageReference(id: $0.chatID, scene: $0.scene, peerID: $0.peerID) }
    }
  }
}
