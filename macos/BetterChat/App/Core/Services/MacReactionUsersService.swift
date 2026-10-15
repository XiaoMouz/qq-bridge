import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacReactionUsersService {
  func load(emojiID: String) async throws -> [Qqbridge_V1_ReactionUser]
}

struct MacSessionReactionUsersService: MacReactionUsersService {
  let session: Session
  let chatID: Int64
  let sequence: Int64

  func load(emojiID: String) async throws -> [Qqbridge_V1_ReactionUser] {
    var request = Qqbridge_V1_ListReactionUsersRequest()
    request.chatID = chatID
    request.seq = sequence
    request.emojiID = emojiID
    return try await session.api.messages.listReactionUsers(request: request, headers: session.api.headers).get().users
  }
}
