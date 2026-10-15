import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacGroupFilesService {
  func load() async throws -> Qqbridge_V1_ListGroupFilesResponse
}

@MainActor
struct MacSessionGroupFilesService: MacGroupFilesService {
  let session: Session
  let groupID: Int64
  let folderID: String

  func load() async throws -> Qqbridge_V1_ListGroupFilesResponse {
    var request = Qqbridge_V1_ListGroupFilesRequest()
    request.groupID = groupID
    request.folderID = folderID
    return try await session.api.contacts.listGroupFiles(request: request, headers: session.api.headers).get()
  }
}
