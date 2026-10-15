import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacAlbumMediaService {
  func page(after cursor: String) async throws -> Qqbridge_V1_ListGroupAlbumMediaResponse
}

@MainActor
struct MacSessionAlbumMediaService: MacAlbumMediaService {
  let session: Session
  let groupID: Int64
  let albumID: String

  func page(after cursor: String) async throws -> Qqbridge_V1_ListGroupAlbumMediaResponse {
    var request = Qqbridge_V1_ListGroupAlbumMediaRequest()
    request.groupID = groupID
    request.albumID = albumID
    request.cursor = cursor
    return try await session.api.contacts.listGroupAlbumMedia(request: request, headers: session.api.headers).get()
  }
}
