import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacChatHistoryService {
  func search(chatID: Int64, query: String, before: Qqbridge_V1_SearchCursor?) async throws -> Qqbridge_V1_SearchMessagesResponse
}

struct MacSessionChatHistoryService: MacChatHistoryService {
  let session: Session

  func search(chatID: Int64, query: String, before: Qqbridge_V1_SearchCursor?) async throws -> Qqbridge_V1_SearchMessagesResponse {
    var request = Qqbridge_V1_SearchMessagesRequest()
    request.chatID = chatID
    request.query = query
    request.limit = 100
    if let before { request.before = before }
    return try await session.api.messages.searchMessages(request: request, headers: session.api.headers).get()
  }
}
