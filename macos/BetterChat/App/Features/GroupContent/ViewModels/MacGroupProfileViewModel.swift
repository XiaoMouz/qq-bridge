import QQBridgeKit
import QQBridgeProto

@MainActor
final class MacGroupProfileViewModel {
  private let resource = MacGroupResource<Qqbridge_V1_GroupProfile>()
  private let groupID: Int64
  private let fetch: @MainActor () async throws -> Qqbridge_V1_GroupProfile
  private var refreshInterrupted = false

  init(groupID: Int64, fetch: @escaping @MainActor () async throws -> Qqbridge_V1_GroupProfile) {
    self.groupID = groupID
    self.fetch = fetch
  }

  convenience init(session: Session, groupID: Int64) {
    self.init(groupID: groupID) {
      var req = Qqbridge_V1_GetGroupProfileRequest()
      req.groupID = groupID
      req.refresh = true
      return try await session.api.contacts.getGroupProfile(request: req, headers: session.api.headers).get().profile
    }
  }

  var profile: Qqbridge_V1_GroupProfile? { resource.value }
  var error: String? { resource.error }
  var isLoading: Bool { resource.isLoading }
  var hasLoaded: Bool { resource.hasLoaded }

  func start() {
    guard !hasLoaded || refreshInterrupted, error == nil else { return }
    load()
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    refreshInterrupted = false
    return resource.load(groupID: groupID, fetch: fetch)
  }

  func cancel() {
    // 刷新途中进入子页，回来继续用户的刷新意图；成功的页面返回时仍不重复请求。
    if isLoading { refreshInterrupted = true }
    resource.cancel()
  }
}
