import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacContactGroupService {
  func load() async throws -> Qqbridge_V1_Dialog
}

struct MacSessionContactGroupService: MacContactGroupService {
  let session: Session
  let groupID: Int64

  func load() async throws -> Qqbridge_V1_Dialog {
    let chatID = try await DialogActions.openChat(session, scene: .group, peerId: groupID)
    try Task.checkCancellation()
    for try await dialog in session.store.observeDialog(chatId: chatID) {
      try Task.checkCancellation()
      if let dialog { return dialog }
    }
    throw CancellationError()
  }
}
