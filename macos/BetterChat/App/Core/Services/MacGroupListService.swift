import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacGroupListService<Item> {
  associatedtype Item: Sendable
  func load() async throws -> [Item]
}

@MainActor
struct MacGroupNoticesService: MacGroupListService {
  let session: Session
  let groupID: Int64

  func load() async throws -> [Qqbridge_V1_GroupNotice] {
    var request = Qqbridge_V1_ListGroupNoticesRequest()
    request.groupID = groupID
    return try await session.api.contacts.listGroupNotices(request: request, headers: session.api.headers).get().notices
  }
}

@MainActor
struct MacGroupAlbumsService: MacGroupListService {
  let session: Session
  let groupID: Int64

  func load() async throws -> [Qqbridge_V1_GroupAlbum] {
    var request = Qqbridge_V1_ListGroupAlbumsRequest()
    request.groupID = groupID
    return try await session.api.contacts.listGroupAlbums(request: request, headers: session.api.headers).get().albums
  }
}

@MainActor
struct MacGroupFoldersService: MacGroupListService {
  let session: Session
  let groupID: Int64

  func load() async throws -> [Qqbridge_V1_GroupFolder] {
    var request = Qqbridge_V1_ListGroupFilesRequest()
    request.groupID = groupID
    return try await session.api.contacts.listGroupFiles(request: request, headers: session.api.headers).get().folders
  }
}
