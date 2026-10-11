// 资料页：个人资料（点群友头像、私聊标题）、群资料（点群聊标题）、@ 选人。
// 打开时带 refresh = true：服务端缓存超过 10 分钟才当场向 QQ 刷新。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct UserProfileView: View {
  let session: Session
  let userId: Int64
  let groupMember: Qqbridge_V1_GroupMember?
  var onMention: (() -> Void)? = nil
  /// 从联系人点开：显示发消息、消息提醒、删除好友。
  var contactActions = false
  var onDeleted: (() -> Void)? = nil
  @Environment(AppModel.self) private var model
  @State private var profile: Qqbridge_V1_UserProfile?
  /// 本地缓存的资料：打开时先用它显示名字、头像、签名，服务端刷新回来再换成新的。
  @State private var cached: Qqbridge_V1_Peer?
  @State private var loading = true
  @State private var dialog: DialogItem?
  @State private var confirmDelete = false
  @State private var actionError: String?

  var body: some View {
    List {
      Section {
        HStack(spacing: 16) {
          AvatarView(sha256: peer.flatMap { $0.avatarSha256.isEmpty ? nil : $0.avatarSha256 }, title: displayName, seed: userId, size: 72)
          VStack(alignment: .leading, spacing: 4) {
            Text(displayName).font(.title3.bold())
            if let p = peer, !p.remark.isEmpty, !p.name.isEmpty, p.remark != p.name {
              Text("昵称：\(p.name)").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("QQ \(String(userId))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        .padding(.vertical, 4)
        if let sign = peer?.sign, !sign.isEmpty {
          Text(sign).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      if let m = groupMember {
        Section("群内") {
          if !m.card.isEmpty { LabeledContent("群名片", value: m.card) }
          LabeledContent("身份", value: m.role == "owner" ? "群主" : m.role == "admin" ? "管理员" : "成员")
          if !m.title.isEmpty { LabeledContent("头衔", value: m.title) }
          if !m.level.isEmpty { LabeledContent("等级", value: m.level) }
          if m.joinedAt > 0 { LabeledContent("入群时间", value: Format.date(m.joinedAt)) }
          if m.lastSentAt > 0 { LabeledContent("最后发言", value: Format.date(m.lastSentAt)) }
        }
      }
      if let p = profile {
        Section("资料") {
          if p.sex != "unknown", !p.sex.isEmpty { LabeledContent("性别", value: p.sex == "male" ? "男" : p.sex == "female" ? "女" : p.sex) }
          if p.age > 0 { LabeledContent("年龄", value: "\(p.age)") }
          if p.level > 0 { LabeledContent("QQ 等级", value: "\(p.level)") }
          LabeledContent("好友", value: p.peer.isFriend ? "是" : "否")
        }
      }
      if let onMention {
        Section { Button("@\(displayName)", systemImage: "at", action: onMention) }
      }
      if contactActions {
        Section {
          Button("发消息", systemImage: "message") { Task { await openChat() } }
        }
        Section("消息设置") {
          Picker("消息提醒", selection: Binding(get: { dialog?.isMuted == true ? "muted" : "all" }, set: { p in Task { await setPolicy(p) } })) {
            Text("接收并提醒").tag("all")
            Text("接收不提醒").tag("muted")
          }
          if let d = dialog {
            Toggle("置顶", isOn: Binding(get: { d.dialog.pinned }, set: { on in
              var req = Qqbridge_V1_SetPinnedRequest()
              req.chatID = d.id
              req.pinned = on
              Task { _ = await session.api.dialogs.setPinned(request: req, headers: session.api.headers) }
            }))
          }
        }
        if peer?.isFriend ?? true {
          Section {
            Button("删除好友", role: .destructive) { confirmDelete = true }
          }
        }
      }
    }
    .navigationTitle("资料")
    .navigationBarTitleDisplayMode(.inline)
    .overlay { if loading && profile == nil && cached == nil { ProgressView() } }
    .onAppear { if cached == nil { cached = try? session.store.peer(kind: .user, peerId: userId) } }
    .confirmationDialog("删除好友后，对方的好友列表里也不会再有你。聊天记录会保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("删除好友", role: .destructive) { Task { await deleteFriend() } }
    }
    .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }), presenting: actionError) { _ in
      Button("好") { actionError = nil }
    } message: { Text($0) }
    .task {
      guard contactActions else { return }
      do {
        for try await list in session.store.observeDialogs(limit: 5000) {
          dialog = list.first { !$0.isGroup && $0.dialog.peerID == userId }
        }
      } catch {}
    }
    .task {
      var req = Qqbridge_V1_GetUserProfileRequest()
      req.userID = userId
      req.refresh = true
      profile = try? await session.api.contacts.getUserProfile(request: req, headers: session.api.headers).get().profile
      loading = false
    }
  }

  private func openChat() async {
    do {
      model.pendingChat = try await DialogActions.openChat(session, scene: .friend, peerId: userId)
    } catch {
      actionError = LoadState.describe(error)
    }
  }

  /// 消息提醒：会话还没有时先建出来（设置挂在会话上）。
  private func setPolicy(_ policy: String) async {
    do {
      let chatId: Int64
      if let id = dialog?.id { chatId = id } else { chatId = try await DialogActions.openChat(session, scene: .friend, peerId: userId) }
      DialogActions.setPolicy(chatId, session, policy == "all" ? "default" : policy)
    } catch {
      actionError = LoadState.describe(error)
    }
  }

  private func deleteFriend() async {
    var req = Qqbridge_V1_DeleteFriendRequest()
    req.userID = userId
    do {
      _ = try await session.api.contacts.deleteFriend(request: req, headers: session.api.headers).get()
      onDeleted?()
    } catch {
      actionError = LoadState.describe(error)
    }
  }

  private var peer: Qqbridge_V1_Peer? { profile?.peer ?? cached }

  private var displayName: String {
    if let m = groupMember, !m.card.isEmpty { return m.card }
    if let p = peer {
      if !p.remark.isEmpty { return p.remark }
      if !p.name.isEmpty { return p.name }
    }
    if let m = groupMember, !m.nickname.isEmpty { return m.nickname }
    return String(userId)
  }
}

struct GroupInfoView: View {
  let session: Session
  let dialog: Qqbridge_V1_Dialog
  let members: GroupMembers
  let avatars: AvatarBook
  var onMention: ((Int64) -> Void)? = nil
  /// 从联系人点开时有：顶部显示"发消息"。
  var onOpenChat: (() -> Void)? = nil
  @State private var profile: Qqbridge_V1_GroupProfile?
  /// 本地缓存的群资料：先显示群名、头像、人数、简介。
  @State private var cached: Qqbridge_V1_Peer?
  @State private var current: Qqbridge_V1_Dialog?
  @State private var profileUser: ProfileTarget?
  @State private var memberQuery = ""

  private var d: Qqbridge_V1_Dialog { current ?? dialog }

  var body: some View {
    List {
      Section {
        HStack(spacing: 16) {
          AvatarView(sha256: groupPeer.flatMap { $0.avatarSha256.isEmpty ? nil : $0.avatarSha256 }, title: groupName, seed: dialog.peerID, size: 72)
          VStack(alignment: .leading, spacing: 4) {
            Text(groupName).font(.title3.bold())
            Text("群号 \(String(dialog.peerID))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
            if let p = profile {
              Text("\(p.peer.memberCount) / \(p.maxMemberCount) 人").font(.subheadline).foregroundStyle(.secondary)
            } else if let c = cached, c.memberCount > 0 {
              Text("\(c.memberCount) 人").font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
        if let sign = groupPeer?.sign, !sign.isEmpty {
          Text(sign).font(.subheadline).foregroundStyle(.secondary)
        }
      }

      if let onOpenChat {
        Section { Button("发消息", systemImage: "message", action: onOpenChat) }
      }

      Section("消息设置") {
        Picker("消息", selection: Binding(get: { d.notifyPolicy == "default" ? "all" : d.notifyPolicy }, set: { setPolicy($0) })) {
          Text("接收并提醒").tag("all")
          Text("只提醒 @我和回复我").tag("mentions")
          Text("接收不提醒").tag("muted")
          Text("收进群助手").tag("archived")
        }
        Toggle("@全体成员 提醒", isOn: Binding(get: { d.mentionAllNotify }, set: { setMentionAll($0) }))
        Toggle("置顶", isOn: Binding(get: { d.pinned }, set: { setPinned($0) }))
      }

      Section {
        NavigationLink("查找聊天记录") { ChatSearchView(session: session, chatId: dialog.chatID) }
        NavigationLink("图片、视频与文件") { SharedMediaView(session: session, chatId: dialog.chatID) }
      }

      Section {
        NavigationLink { GroupNoticesView(session: session, groupId: dialog.peerID) } label: { Label("群公告", systemImage: "megaphone") }
        NavigationLink { GroupEssenceView(session: session, groupId: dialog.peerID, chatId: dialog.chatID) } label: { Label("群精华", systemImage: "star") }
        NavigationLink { GroupFilesView(session: session, groupId: dialog.peerID) } label: { Label("群文件", systemImage: "folder") }
      }

      Section("成员 \(members.list.count)") {
        TextField("搜索成员", text: $memberQuery)
        ForEach(filteredMembers.prefix(200), id: \.userID) { m in
          Button { profileUser = ProfileTarget(userId: m.userID) } label: {
            HStack(spacing: 12) {
              AvatarView(sha256: avatars.sha256[m.userID], title: memberName(m), seed: m.userID, size: 36)
                .onAppear { avatars.want(m.userID, session: session) }
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                  Text(memberName(m)).foregroundStyle(.primary)
                  if m.role == "owner" { RoleTag(text: "群主", color: .orange) } else if m.role == "admin" { RoleTag(text: "管理员", color: .green) }
                }
                if !m.title.isEmpty { Text(m.title).font(.caption).foregroundStyle(.secondary) }
              }
            }
          }
          .tint(.primary)
          .contextMenu {
            if let onMention { Button("@\(memberName(m))", systemImage: "at") { onMention(m.userID) } }
          }
        }
      }
    }
    .navigationTitle("群资料")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { if cached == nil { cached = try? session.store.peer(kind: .group, peerId: dialog.peerID) } }
    .sheet(item: $profileUser) { t in
      NavigationStack {
        UserProfileView(session: session, userId: t.userId, groupMember: members.byId[t.userId], onMention: onMention.map { mention in
          {
            profileUser = nil
            mention(t.userId)
          }
        })
      }
      .presentationDetents([.medium, .large])
    }
    .task {
      var req = Qqbridge_V1_GetGroupProfileRequest()
      req.groupID = dialog.peerID
      req.refresh = true
      profile = try? await session.api.contacts.getGroupProfile(request: req, headers: session.api.headers).get().profile
      await members.load(session: session, groupId: dialog.peerID, refresh: true)
    }
    .task {
      do {
        for try await list in session.store.observeDialogs() {
          current = list.first { $0.id == dialog.chatID }?.dialog
        }
      } catch {}
    }
  }

  private var groupPeer: Qqbridge_V1_Peer? { profile?.peer ?? cached }

  private var groupName: String {
    if let p = groupPeer, !p.name.isEmpty { return p.name }
    return String(dialog.peerID)
  }

  private var filteredMembers: [Qqbridge_V1_GroupMember] {
    let q = memberQuery.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return members.list }
    return members.list.filter { memberName($0).localizedCaseInsensitiveContains(q) || $0.nickname.localizedCaseInsensitiveContains(q) || String($0.userID).contains(q) }
  }

  private func memberName(_ m: Qqbridge_V1_GroupMember) -> String {
    !m.card.isEmpty ? m.card : (!m.nickname.isEmpty ? m.nickname : String(m.userID))
  }

  private func setPolicy(_ p: String) { DialogActions.setPolicy(dialog.chatID, session, p) }

  private func setPinned(_ on: Bool) {
    var req = Qqbridge_V1_SetPinnedRequest()
    req.chatID = dialog.chatID
    req.pinned = on
    Task { _ = await session.api.dialogs.setPinned(request: req, headers: session.api.headers) }
  }

  private func setMentionAll(_ on: Bool) {
    var req = Qqbridge_V1_SetMentionAllNotifyRequest()
    req.chatID = dialog.chatID
    req.enabled = on
    Task { _ = await session.api.dialogs.setMentionAllNotify(request: req, headers: session.api.headers) }
  }
}

/// @ 选人：可搜索群名片、昵称、号码；第一项是 @全体成员。
struct MentionPicker: View {
  let members: GroupMembers
  let avatars: AvatarBook
  let session: Session
  let onPick: ((userId: Int64, name: String)?) -> Void
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        if query.isEmpty {
          Button { onPick((0, "全体成员")) } label: { Label("@全体成员", systemImage: "person.3.fill") }
        }
        ForEach(filtered.prefix(300), id: \.userID) { m in
          Button { onPick((m.userID, name(m))) } label: {
            HStack(spacing: 12) {
              AvatarView(sha256: avatars.sha256[m.userID], title: name(m), seed: m.userID, size: 32)
                .onAppear { avatars.want(m.userID, session: session) }
              Text(name(m)).foregroundStyle(.primary)
              Spacer()
              Text(String(m.userID)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
          }
          .tint(.primary)
        }
      }
      .listStyle(.plain)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索群成员")
      .navigationTitle("选择要 @ 的人")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { onPick(nil) } } }
    }
  }

  private var filtered: [Qqbridge_V1_GroupMember] {
    let q = query.trimmingCharacters(in: .whitespaces)
    let list = members.list.sorted { $0.lastSentAt > $1.lastSentAt }  // 最近发过言的在前
    guard !q.isEmpty else { return list }
    return list.filter { name($0).localizedCaseInsensitiveContains(q) || $0.nickname.localizedCaseInsensitiveContains(q) || String($0.userID).contains(q) }
  }

  private func name(_ m: Qqbridge_V1_GroupMember) -> String {
    !m.card.isEmpty ? m.card : (!m.nickname.isEmpty ? m.nickname : String(m.userID))
  }
}

extension Format {
  static func date(_ unix: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(unix)).formatted(.dateTime.year().month().day().locale(locale))
  }
}
