// 联系人：好友按 QQ 的分组折叠显示（特别关心在最前），群聊一个列表；头像显示到时才要。
// 点开好友是资料页（发消息、消息提醒、删除好友），点开群是群资料（发消息、消息设置、群公告等）。
// "发消息"切到消息页并打开会话（会话还没有时服务端新建）。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

enum ContactRoute: Hashable {
  case user(Int64)
  case group(Int64)
}

struct ContactsView: View {
  let session: Session
  @State private var friends: [Qqbridge_V1_Peer] = []
  @State private var categories: [Qqbridge_V1_FriendCategory] = []
  @State private var groups: [Qqbridge_V1_Peer] = []
  @State private var showGroups = false
  @State private var query = ""
  @State private var expanded: Set<Int32> = []
  @State private var avatars = AvatarBook()
  @State private var error: String?
  @State private var path = NavigationPath()

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Picker("", selection: $showGroups) {
          Text("好友 \(friends.count)").tag(false)
          Text("群聊 \(groups.count)").tag(true)
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)

        if showGroups {
          ForEach(filter(groups), id: \.peerID) { groupRow($0) }
        } else if !query.isEmpty || categories.isEmpty {
          ForEach(filter(friends), id: \.peerID) { friendRow($0) }
        } else {
          ForEach(categories, id: \.id) { c in
            DisclosureGroup(isExpanded: expandedBinding(c.id)) {
              ForEach(c.userIds, id: \.self) { id in
                if let p = friendsById[id] { friendRow(p) }
              }
            } label: {
              HStack {
                Text(c.name.isEmpty ? "未命名分组" : c.name).font(.headline)
                Spacer()
                Text("\(c.userIds.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
              }
            }
          }
          let ungrouped = friends.filter { !categorized.contains($0.peerID) }
          if !ungrouped.isEmpty {
            DisclosureGroup(isExpanded: expandedBinding(-1)) {
              ForEach(ungrouped, id: \.peerID) { friendRow($0) }
            } label: {
              HStack {
                Text("未分组").font(.headline)
                Spacer()
                Text("\(ungrouped.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .listStyle(.plain)
      .navigationTitle("联系人")
      .searchable(text: $query, prompt: showGroups ? "搜索群聊" : "搜索好友")
      .navigationDestination(for: ContactRoute.self) { route in
        switch route {
        case .user(let id):
          UserProfileView(session: session, userId: id, groupMember: nil, contactActions: true, onDeleted: {
            if !path.isEmpty { path.removeLast() }
            Task { await load(refresh: false) }
          })
        case .group(let id):
          ContactGroupView(session: session, groupId: id)
        }
      }
      .refreshable { await load(refresh: true) }
      .task { await load(refresh: false) }
      .overlay {
        if let error, friends.isEmpty, groups.isEmpty {
          ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
        }
      }
    }
  }

  private var friendsById: [Int64: Qqbridge_V1_Peer] {
    Dictionary(friends.map { ($0.peerID, $0) }, uniquingKeysWith: { a, _ in a })
  }

  /// 在某个普通分组里的人（特别关心的人同时也在自己的分组里，不算）。
  private var categorized: Set<Int64> {
    Set(categories.filter { !$0.specialCare }.flatMap(\.userIds))
  }

  private func expandedBinding(_ id: Int32) -> Binding<Bool> {
    Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
  }

  private func filter(_ list: [Qqbridge_V1_Peer]) -> [Qqbridge_V1_Peer] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return list }
    return list.filter {
      $0.name.localizedCaseInsensitiveContains(q) || $0.remark.localizedCaseInsensitiveContains(q) || String($0.peerID).contains(q)
    }
  }

  private func friendRow(_ p: Qqbridge_V1_Peer) -> some View {
    NavigationLink(value: ContactRoute.user(p.peerID)) {
      HStack(spacing: 12) {
        AvatarView(sha256: p.avatarSha256.isEmpty ? avatars.sha256[p.peerID] : p.avatarSha256, title: displayName(p), seed: p.peerID, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(displayName(p)).lineLimit(1)
          if !p.sign.isEmpty { Text(p.sign).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
      }
    }
    .onAppear { if p.avatarSha256.isEmpty { avatars.want(p.peerID, session: session) } }
  }

  private func groupRow(_ p: Qqbridge_V1_Peer) -> some View {
    NavigationLink(value: ContactRoute.group(p.peerID)) {
      HStack(spacing: 12) {
        AvatarView(sha256: p.avatarSha256.isEmpty ? avatars.groupSha256[p.peerID] : p.avatarSha256, title: displayName(p), seed: p.peerID, size: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(displayName(p)).lineLimit(1)
          if p.memberCount > 0 { Text("\(p.memberCount) 人").font(.caption).foregroundStyle(.secondary) }
        }
      }
    }
    .onAppear { if p.avatarSha256.isEmpty { avatars.wantGroup(p.peerID, session: session) } }
  }

  private func displayName(_ p: Qqbridge_V1_Peer) -> String {
    !p.remark.isEmpty ? p.remark : (!p.name.isEmpty ? p.name : String(p.peerID))
  }

  private static func sorted(_ list: [Qqbridge_V1_Peer]) -> [Qqbridge_V1_Peer] {
    let name = { (p: Qqbridge_V1_Peer) in !p.remark.isEmpty ? p.remark : p.name }
    return list.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
  }

  private func load(refresh: Bool) async {
    // 先用本地缓存显示（名字、头像都有），再等服务端的列表和分组。
    if friends.isEmpty, groups.isEmpty {
      friends = Self.sorted((try? session.store.peers(kind: .user, friendsOnly: true)) ?? [])
      groups = Self.sorted((try? session.store.peers(kind: .group)) ?? [])
    }
    let api = session.api
    if refresh { _ = await api.contacts.refreshContacts(request: .init(), headers: api.headers) }
    do {
      let res = try await api.contacts.listFriends(request: .init(), headers: api.headers).get()
      friends = res.friends
      categories = res.categories
      groups = try await api.contacts.listGroups(request: .init(), headers: api.headers).get().groups
      error = nil
    } catch {
      self.error = LoadState.describe(error)
    }
  }
}

/// 从联系人点开的群：先拿到（或新建）会话，再显示群资料页，顶部多一个"发消息"。
struct ContactGroupView: View {
  let session: Session
  let groupId: Int64
  @Environment(AppModel.self) private var model
  @State private var dialog: Qqbridge_V1_Dialog?
  @State private var members = GroupMembers()
  @State private var avatars = AvatarBook()
  @State private var error: String?

  var body: some View {
    Group {
      if let dialog {
        GroupInfoView(session: session, dialog: dialog, members: members, avatars: avatars, onOpenChat: {
          model.pendingChat = dialog.chatID
        })
      } else if let error {
        ContentUnavailableView("打不开", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        ProgressView()
      }
    }
    .task {
      do {
        let chatId = try await DialogActions.openChat(session, scene: .group, peerId: groupId)
        // 新建的会话经同步到本地库要一会儿：等它出现。
        for try await list in session.store.observeDialogs(limit: 5000) {
          if let d = list.first(where: { $0.id == chatId })?.dialog {
            dialog = d
            break
          }
        }
      } catch {
        self.error = LoadState.describe(error)
      }
    }
  }
}

extension DialogActions {
  /// 拿到和某人 / 某群的会话 id（没有就让服务端新建）。
  static func openChat(_ session: Session, scene: Qqbridge_V1_Scene, peerId: Int64) async throws -> Int64 {
    var req = Qqbridge_V1_OpenChatRequest()
    req.scene = scene
    req.peerID = peerId
    return try await session.api.dialogs.openChat(request: req, headers: session.api.headers).get().chatID
  }
}
