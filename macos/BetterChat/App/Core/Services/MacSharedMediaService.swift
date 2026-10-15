import QQBridgeKit
import QQBridgeProto

struct MacSharedMediaQuery: Equatable, Sendable {
  let files: Bool
  let sort: String
  var usesSequence: Bool { sort == "time_desc" }
}

@MainActor
protocol MacSharedMediaService {
  func page(query: MacSharedMediaQuery, before: Int64, offset: Int32) async throws -> Qqbridge_V1_ListSharedMediaResponse
}

@MainActor
struct MacSessionSharedMediaService: MacSharedMediaService {
  let session: Session
  let chatID: Int64
  func page(query: MacSharedMediaQuery, before: Int64, offset: Int32) async throws -> Qqbridge_V1_ListSharedMediaResponse {
    var request = Qqbridge_V1_ListSharedMediaRequest()
    request.chatID = chatID
    request.kinds = query.files ? [.file] : [.image, .video]
    request.sort = query.sort
    request.limit = 80
    if query.usesSequence { request.beforeSeq = before }
    else { request.offset = offset }
    return try await session.api.messages.listSharedMedia(request: request, headers: session.api.headers).get()
  }
}
