// 资料页：个人资料（点群友头像、私聊标题）、群资料（点群聊标题）、@ 选人。
// 打开时带 refresh = true：服务端缓存超过 10 分钟才当场向 QQ 刷新。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

extension View {
  @ViewBuilder
  func profileCard<Content: View>(item: Binding<ProfileTarget?>, @ViewBuilder content: @escaping (ProfileTarget) -> Content) -> some View {
    #if targetEnvironment(macCatalyst)
    background(MacProfileCardPresenter(item: item, content: content))
    #else
    sheet(item: item, content: content)
    #endif
  }
}

struct UserProfileView: View {
  let session: Session
  let userId: Int64
  let groupMember: Qqbridge_V1_GroupMember?
  var onMention: (() -> Void)? = nil
  /// 旧参数（以前只有从联系人点开才显示消息设置、删除好友）：现在都按是不是好友决定，留着兼容调用处。
  var contactActions = false
  var onDeleted: (() -> Void)? = nil
  /// 从群里点开的资料卡：所在的群（发起私聊时对方不是好友就走群临时会话）。
  var viaGroupId: Int64 = 0
  /// 作为弹出卡片显示：不要顶部的「资料」标题栏。
  var asCard = false
  /// 从 Mac 会话详情进入时明确传入当前会话，避免临时会话和普通私聊混查。
  var conversationID: Int64? = nil
  /// 卡片宿主显式清除自己的 sheet 选择，避免关闭动作落在内部导航环境。
  var onClose: (() -> Void)? = nil
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var profile: Qqbridge_V1_UserProfile?
  /// 本地缓存的资料：打开时先用它显示名字、头像、签名，服务端刷新回来再换成新的。
  @State private var cached: Qqbridge_V1_Peer?
  @State private var loading = true
  @State private var dialog: DialogItem?
  @State private var confirmDelete = false
  @State private var actionError: String?
  #if targetEnvironment(macCatalyst)
  @State private var openRequest = MacChatOpenRequest()
  #endif

  var body: some View {
    List {
      Section {
        HStack(spacing: 16) {
          AvatarView(sha256: peer.flatMap { $0.avatarSha256.isEmpty ? nil : $0.avatarSha256 }, title: qqName, seed: userId, size: 72)
          VStack(alignment: .leading, spacing: 4) {
            // 顶部：备注 > QQ 昵称（群名片在下面「群内」里单独显示）。
            Text(qqName).font(.title3.bold())
            if let remark = peer?.remark, !remark.isEmpty, !nickname.isEmpty, remark != nickname {
              Text("昵称：\(nickname)").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("QQ \(String(userId))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        .padding(.vertical, 4)
        if let sign = peer?.sign, !sign.isEmpty {
          Text(sign).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      #if targetEnvironment(macCatalyst)
      if let conversationID {
        Section {
          NavigationLink { ChatSearchView(session: session, chatId: conversationID) } label: {
            Label("查找聊天记录", systemImage: "magnifyingglass")
          }
          NavigationLink { SharedMediaView(session: session, chatId: conversationID) } label: {
            Label("图片、视频与文件", systemImage: "photo.on.rectangle")
          }
        }
      }
      #endif
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
      // 不管从哪里点开都一样：发消息（不是好友、从群里点开时走群临时会话）；好友才有消息设置和删除好友，不是好友显示加好友。
      if !isSelf {
        Section {
          #if targetEnvironment(macCatalyst)
          Button(action: openMacChat) {
            HStack {
              Label("发消息", systemImage: "message")
              if openRequest.peerKey != nil { Spacer(); ProgressView().controlSize(.small) }
            }
          }
          .disabled(openRequest.peerKey != nil)
          #else
          Button("发消息", systemImage: "message") { Task { await openChat() } }
          #endif
          if !isFriend {
            Button("加好友", systemImage: "person.badge.plus") {
              actionError = "QQ 的接口不支持主动加好友，请在手机 QQ 里添加 \(qqName)（QQ \(String(userId))）"
            }
          }
        }
      }
      if !isSelf, isFriend {
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
        Section {
          Button("删除好友", role: .destructive) { confirmDelete = true }
            // 挂在按钮上：确认框从按钮弹出（挂在整个列表上会从屏幕中间 / 顶上冒出来，和按钮对不上）。
            .confirmationDialog("删除好友后，对方的好友列表里也不会再有你。聊天记录会保留。", isPresented: $confirmDelete, titleVisibility: .visible) {
              Button("删除好友", role: .destructive) { Task { await deleteFriend() } }
            }
        }
      }
    }
    .navigationTitle("资料")
    .navigationBarTitleDisplayMode(.inline)
    #if targetEnvironment(macCatalyst)
    // Mac 资料卡没有 iPhone 的下拉关闭手势，保留可见的退出入口。
    .toolbar {
      if asCard {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            openRequest.cancel()
            if let onClose { onClose() } else { dismiss() }
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
    .onDisappear { openRequest.cancel() }
    #else
    .toolbar(asCard ? .hidden : .automatic, for: .navigationBar)
    #endif
    .overlay { if loading && profile == nil && cached == nil { ProgressView() } }
    .onAppear { if cached == nil { cached = try? session.store.peer(kind: .user, peerId: userId) } }
    .alert("操作失败", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }), presenting: actionError) { _ in
      Button("好") { actionError = nil }
    } message: { Text($0) }
    .task {
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

  #if targetEnvironment(macCatalyst)
  private func openMacChat() {
    actionError = nil
    // 关闭卡片或切到别的资料后，迟到的建会话响应不能再改变工作区路由。
    openRequest.start(peerKey: "\(userId):\(viaGroupId)", operation: {
      try await DialogActions.openChat(session, scene: .friend, peerId: userId, viaGroupId: viaGroupId)
    }, opened: { chatID in
      onClose?()
      model.pendingChat = chatID
    }, failed: { actionError = LoadState.describe($0) })
  }
  #else
  private func openChat() async {
    do {
      let chatID = try await DialogActions.openChat(session, scene: .friend, peerId: userId, viaGroupId: viaGroupId)
      // 先清除资料卡选择，避免宿主保留原资料页时，弹窗继续遮住新会话。
      onClose?()
      model.pendingChat = chatID
    } catch {
      actionError = LoadState.describe(error)
    }
  }
  #endif

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

  private var isSelf: Bool { userId == model.qqAccount?.uin }

  /// 好友：资料里的 is_friend；还没拉到资料时看本地会话列表里有没有这个私聊。
  private var isFriend: Bool { peer?.isFriend ?? (dialog != nil) }

  /// QQ 昵称（不是群名片）。
  private var nickname: String {
    if let n = peer?.name, !n.isEmpty { return n }
    if let n = groupMember?.nickname, !n.isEmpty { return n }
    return ""
  }

  /// 顶部显示的名字：备注 > QQ 昵称 > 号码。
  private var qqName: String {
    if let r = peer?.remark, !r.isEmpty { return r }
    return nickname.isEmpty ? String(userId) : nickname
  }

  /// @ 按钮、提示里用的名字：群里用群名片。
  private var displayName: String {
    if let m = groupMember, !m.card.isEmpty { return m.card }
    return qqName
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
  #if targetEnvironment(macCatalyst)
  /// 模型要 session、groupID 才能建，放在 task 里懒创建，免得改两个调用点的参数。
  @State private var macProfile: MacGroupProfileViewModel?
  /// 成员列表只在本页第一次出现时强制刷新；从群公告等子页返回时不再重拉，避免打断已显示的列表和错误状态。
  @State private var macMembersRequested = false
  #endif

  private var d: Qqbridge_V1_Dialog { current ?? dialog }

  var body: some View {
    #if targetEnvironment(macCatalyst)
    content
      .toolbar { macRefreshToolbar }
      .task { startMacLoading() }
      // 只作废资料请求；成员列表是聊天页共用的缓存，请求由 GroupMembers 自己的生命周期管，这里不取消。
      .onDisappear { macProfile?.cancel() }
      .task {
        // 直接观察这一个会话，不受会话列表 500 条上限影响（群多时当前群可能不在前 500 条里）。
        do {
          for try await value in session.store.observeDialog(chatId: dialog.chatID) { current = value }
        } catch {}
      }
    #else
    content
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
    #endif
  }

  private var content: some View {
    List {
      Section {
        HStack(spacing: 16) {
          AvatarView(sha256: groupPeer.flatMap { $0.avatarSha256.isEmpty ? nil : $0.avatarSha256 }, title: groupName, seed: dialog.peerID, size: 72)
          VStack(alignment: .leading, spacing: 4) {
            Text(groupName).font(.title3.bold())
            Text("群号 \(String(dialog.peerID))").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
            if let p = loadedProfile {
              Text("\(p.peer.memberCount) / \(p.maxMemberCount) 人").font(.subheadline).foregroundStyle(.secondary)
            } else if let c = cached, c.memberCount > 0 {
              Text("\(c.memberCount) 人").font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
        if let sign = groupPeer?.sign, !sign.isEmpty {
          Text(sign).font(.subheadline).foregroundStyle(.secondary)
        }
        #if targetEnvironment(macCatalyst)
        macProfileStatus
        #endif
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
        NavigationLink { GroupFilesView(session: session, groupId: dialog.peerID, chatId: dialog.chatID, selfRole: groupPeer?.selfRole ?? "") } label: { Label("群文件", systemImage: "folder") }
        NavigationLink { GroupAlbumsView(session: session, groupId: dialog.peerID) } label: { Label("群相册", systemImage: "photo.on.rectangle.angled") }
      }

      Section(membersTitle) {
        TextField("搜索成员", text: $memberQuery)
        #if targetEnvironment(macCatalyst)
        macMembersStatus
        #endif
        ForEach(filteredMembers.prefix(200), id: \.userID) { m in memberRow(m) }
      }
    }
    .navigationTitle("群资料")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { if cached == nil { cached = try? session.store.peer(kind: .group, peerId: dialog.peerID) } }
    .profileCard(item: $profileUser) { t in
      NavigationStack {
        UserProfileView(session: session, userId: t.userId, groupMember: members.byId[t.userId], onMention: onMention.map { mention in
          {
            profileUser = nil
            mention(t.userId)
          }
        }, viaGroupId: dialog.peerID, asCard: true, onClose: { profileUser = nil })
      }
      #if targetEnvironment(macCatalyst)
      .presentationSizing(.form)
      #else
      .presentationDetents([.medium, .large])
      #endif
    }
  }

  private func memberRow(_ m: Qqbridge_V1_GroupMember) -> some View {
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

  /// Mac 读模型里的资料（失败时模型保留旧值），iOS 仍用原来的 State。
  private var loadedProfile: Qqbridge_V1_GroupProfile? {
    #if targetEnvironment(macCatalyst)
    return macProfile?.profile
    #else
    return profile
    #endif
  }

  private var membersTitle: String {
    #if targetEnvironment(macCatalyst)
    // 成员还没成功加载过时人数未知，写「成员 0」会被当成空群。
    return (members.hasLoaded || !members.list.isEmpty) ? "成员 \(members.list.count)" : "成员"
    #else
    return "成员 \(members.list.count)"
    #endif
  }

  #if targetEnvironment(macCatalyst)
  /// 资料请求的状态：失败时上面仍显示缓存 / 旧资料，这里只补一行错误和重试。
  @ViewBuilder private var macProfileStatus: some View {
    if let vm = macProfile {
      if let error = vm.error {
        HStack {
          Label("群资料刷新失败：\(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
          Spacer()
          Button("重试") { reloadMacProfile() }.disabled(vm.isLoading)
        }
      } else if vm.isLoading, vm.profile == nil {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在加载群资料…").foregroundStyle(.secondary) }
      }
    }
  }

  /// 成员区的几种状态分开显示：加载中、失败（旧列表照常列在下面）、成功但为空、搜索无匹配。
  @ViewBuilder private var macMembersStatus: some View {
    if let error = members.error {
      HStack {
        Label("成员列表加载失败：\(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        Spacer()
        Button("重试") { reloadMacMembers() }.disabled(members.isLoading)
      }
    } else if members.isLoading, members.list.isEmpty {
      HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在加载成员…").foregroundStyle(.secondary) }
    } else if members.hasLoaded, members.list.isEmpty {
      Text("没有成员").foregroundStyle(.secondary)
    }
    let q = memberQuery.trimmingCharacters(in: .whitespaces)
    if !q.isEmpty, !members.list.isEmpty, filteredMembers.isEmpty {
      Text("没有匹配「\(q)」的成员").foregroundStyle(.secondary)
    }
  }

  /// 顶部按钮写明「刷新群资料」，和侧栏的刷新联系人区分开；资料和成员一起刷新。
  @ToolbarContentBuilder private var macRefreshToolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button { reloadMacProfile(); reloadMacMembers() } label: { Label("刷新群资料", systemImage: "arrow.clockwise") }
        .help("刷新群资料和成员列表")
        .disabled((macProfile?.isLoading ?? true) && members.isLoading)
    }
  }

  private func startMacLoading() {
    if macProfile == nil { macProfile = MacGroupProfileViewModel(session: session, groupID: dialog.peerID) }
    // start() 只在还没成功且没有错误时加载：返回到已加载的页面不重拉，已显示的错误也留给用户点重试。
    _ = macProfile?.start()
    if !macMembersRequested {
      macMembersRequested = true
      reloadMacMembers()
    }
  }

  /// 以模型状态防重复：正在请求时不再发第二个。
  private func reloadMacProfile() {
    guard let vm = macProfile, !vm.isLoading else { return }
    _ = vm.load()
  }

  /// 不放在 .task 里 await：页面消失会取消 task，连带取消聊天页也在用的共享成员请求。
  private func reloadMacMembers() {
    // 模型合并相同刷新，并允许强制刷新替换仍在进行的普通缓存读取。
    Task { await members.load(session: session, groupId: dialog.peerID, refresh: true) }
  }
  #endif

  private var groupPeer: Qqbridge_V1_Peer? { loadedProfile?.peer ?? cached }

  private var groupName: String {
    if let p = groupPeer, !p.name.isEmpty { return p.name }
    return String(dialog.peerID)
  }

  private var filteredMembers: [Qqbridge_V1_GroupMember] {
    let q = memberQuery.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return members.list }
    return members.list.filter { members.matches($0, q) }
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
              VStack(alignment: .leading, spacing: 1) {
                Text(name(m)).foregroundStyle(.primary)
                if let sub = members.subtitle(m) { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
              }
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
    return list.filter { members.matches($0, q) }
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
