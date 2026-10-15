import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

/// 联系人左栏：好友按 QQ 分组折叠（特别关心在前），群聊一个列表；筛选、展开状态与加载都在这里。
/// 切换分区不销毁本对象，展开的分组与“好友 / 群聊”选择因此保留。
@MainActor
@Observable
final class MacContactsViewModel {
  struct Category: Identifiable, Equatable {
    let id: Int32
    let title: String
    let people: [Qqbridge_V1_Peer]
  }
  enum Content: Equatable {
    case flat([Qqbridge_V1_Peer])
    case categories([Category])
  }

  private(set) var friends: [Qqbridge_V1_Peer] = []
  private(set) var categories: [Qqbridge_V1_FriendCategory] = []
  private(set) var groups: [Qqbridge_V1_Peer] = []
  var showsGroups = false
  private(set) var expanded: Set<Int32> = []
  private(set) var error: String?
  private(set) var isRefreshing = false
  let avatars = AvatarBook()

  @ObservationIgnored private let service: any MacContactsService
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var started = false

  init(service: any MacContactsService) { self.service = service }
  deinit { task?.cancel() }

  // MARK: 意图

  func start() {
    guard !started else { return }
    started = true
    load(refresh: false)
  }
  func refresh() { load(refresh: true) }
  /// 删除好友等写操作后重新读取，不清空已经显示的列表。
  func reload() { load(refresh: false) }

  func setExpanded(_ id: Int32, _ expanded: Bool) {
    if expanded { self.expanded.insert(id) } else { self.expanded.remove(id) }
  }
  func wantAvatar(_ peer: Qqbridge_V1_Peer) {
    guard peer.avatarSha256.isEmpty else { return }
    service.requestAvatar(for: peer, in: avatars)
  }

  // MARK: 输出

  func content(matching query: String) -> Content {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if showsGroups { return .flat(filter(groups, term)) }
    if !term.isEmpty || categories.isEmpty { return .flat(filter(friends, term)) }
    let byID = Dictionary(friends.map { ($0.peerID, $0) }, uniquingKeysWith: { a, _ in a })
    var result = categories.map { category in
      Category(id: category.id, title: category.name.isEmpty ? "未命名分组" : category.name,
               people: category.userIds.compactMap { byID[$0] })
    }
    // 特别关心的人同时也在自己的分组里，不算进“已分组”。
    let categorized = Set(categories.filter { !$0.specialCare }.flatMap(\.userIds))
    let ungrouped = friends.filter { !categorized.contains($0.peerID) }
    if !ungrouped.isEmpty { result.append(Category(id: -1, title: "未分组", people: ungrouped)) }
    return .categories(result)
  }

  func isEmpty(matching query: String) -> Bool {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !term.isEmpty && filter(showsGroups ? groups : friends, term).isEmpty
  }
  var showsLoadError: Bool { error != nil && friends.isEmpty && groups.isEmpty }

  func avatar(for peer: Qqbridge_V1_Peer) -> MacAvatar {
    let sha = peer.avatarSha256.isEmpty
      ? (peer.kind == .group ? avatars.groupSha256[peer.peerID] : avatars.sha256[peer.peerID])
      : peer.avatarSha256
    return MacAvatar(sha256: sha, title: Self.name(peer), seed: peer.peerID)
  }
  func subtitle(for peer: Qqbridge_V1_Peer) -> String? { MacPeerPresentation.contactSubtitle(peer) }
  static func name(_ peer: Qqbridge_V1_Peer) -> String { MacPeerPresentation.name(peer) }

  // MARK: 内部

  private func filter(_ list: [Qqbridge_V1_Peer], _ term: String) -> [Qqbridge_V1_Peer] {
    guard !term.isEmpty else { return list }
    return list.filter { MacPeerPresentation.matches($0, term) }
  }

  private static func sorted(_ list: [Qqbridge_V1_Peer]) -> [Qqbridge_V1_Peer] {
    let name = { (p: Qqbridge_V1_Peer) in !p.remark.isEmpty ? p.remark : p.name }
    return list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
  }

  private func load(refresh: Bool) {
    if friends.isEmpty, groups.isEmpty {
      let cached = service.cached()
      friends = Self.sorted(cached.friends)
      groups = Self.sorted(cached.groups)
    }
    task?.cancel()
    let id = UUID()
    generation = id
    isRefreshing = refresh
    task = Task { [weak self, service] in
      do {
        let snapshot = try await service.load(refresh: refresh)
        guard let self, self.generation == id, !Task.isCancelled else { return }
        self.friends = snapshot.friends
        self.categories = snapshot.categories
        self.groups = snapshot.groups
        self.error = nil
        self.isRefreshing = false
        self.task = nil
      } catch {
        guard let self, self.generation == id, !Task.isCancelled else { return }
        self.error = LoadState.describe(error)
        self.isRefreshing = false
        self.task = nil
      }
    }
  }
}
