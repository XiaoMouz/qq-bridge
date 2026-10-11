// 聊天页：消息列表（UIKit 集合视图，见 ChatCollectionView）+ 玻璃输入栏。
// 数据流：打开时让同步引擎拉首屏 / 补变化 → 观察本地库 → 列表刷新；滑到顶部时往上翻页；看到底部就标已读。
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct ChatScreen: View {
  let session: Session
  let chatId: Int64
  @Environment(AppModel.self) private var model
  @State private var items: [ChatItem] = []
  @State private var limit = 60
  @State private var dialog: Qqbridge_V1_Dialog?
  @State private var peer: Qqbridge_V1_Peer?
  @State private var selfUin: Int64 = 0
  @State private var loadingOlder = false
  /// 正在向服务端要更早的消息（顶部显示加载中）。
  @State private var fetchingOlder = false
  @State private var reachedStart = false
  @State private var composer = Composer()
  @State private var members = GroupMembers()
  @State private var avatars = AvatarBook()
  @State private var requester = MediaRequester()
  @State private var selection = MessageSelection()
  /// 要转发的消息和方式（选好会话后发给服务端）。
  @State private var pendingForward: PendingForward?
  /// 撤回别人的消息前先确认。
  @State private var confirmRecall: Qqbridge_V1_Message?
  @State private var voice = VoicePlayer()
  @State private var actions = ChatActions()
  @State private var sendError: String?
  @State private var profileUser: ProfileTarget?
  @State private var mediaTarget: MediaTarget?
  @State private var fileURL: URL?
  @State private var forwardMessage: Qqbridge_V1_Message?
  @State private var showInfo = false
  @State private var showStickers = false
  @State private var recorder = VoiceRecorder()
  @State private var photoItems: [PhotosPickerItem] = []
  @State private var showPhotos = false
  @State private var showFiles = false
  /// 正在上传的附件：名字和进度（0…1）。
  @State private var uploading: (name: String, progress: Double)?
  @State private var atBottom = true
  @State private var lastMarked: Int64 = 0
  /// 右下角"有人@我"：未读的 @我 / 回复我 / @全体成员，由近到远（最新的在最前），点一次跳一条。
  @State private var mentions: [MentionTarget] = []
  @State private var scrollRequest: ChatScrollRequest?
  @State private var highlight = MessageHighlight()
  @State private var lookup = ChatLookup()
  @State private var timeReveal = TimeReveal()
  @State private var bubbleFrames = BubbleFrames()
  /// 往上翻时顶部显示的日期（停下一会儿后消失）。
  @State private var scrollDay: String?
  @State private var scrollDayHide: Task<Void, Never>?
  /// items 每变一次加一（列表只在它变了时才重新提交）。
  @State private var itemsVersion = 0
  /// 已经告诉服务端看过的 @（免得重复发）。
  @State private var seenMentions: Set<Int64> = []
  /// 屏幕中间偏上的一行提示（例如跳转的消息加载不到），过两秒消失。
  @State private var notice: String?
  /// 剪贴板里有图片：输入框获得焦点时显示"粘贴图片"。
  @State private var canPaste = false
  /// 有东西拖到聊天页上方：显示"松手发送"。
  @State private var dropTargeted = false
  /// 最后一次停在底部时看到的最后一条消息：之后来的算"新消息"，显示在回到底部按钮上。
  @State private var bottomMark: Int64 = 0
  /// 列表里见过的最新一条：再来的新消息里有 @ / 回复就加进"有人@我"。
  @State private var newestSeen: Int64 = 0
  @FocusState private var inputFocused: Bool

  private var isGroup: Bool { dialog?.scene == .group }

  private var title: String {
    if let p = peer {
      if !p.remark.isEmpty { return p.remark }
      if !p.name.isEmpty { return p.name }
    }
    return dialog.map { String($0.peerID) } ?? ""
  }

  var body: some View {
    ChatCollectionView(
      items: items,
      version: itemsVersion,
      context: MessageContext(
        selfUin: selfUin,
        isGroup: isGroup,
        qqAccountId: dialog?.qqAccountID ?? 0,
        chatId: chatId,
        store: session.store,
        members: members,
        avatars: avatars,
        requester: requester,
        selection: selection,
        voice: voice,
        actions: actions,
        session: session,
        highlight: highlight,
        lookup: lookup,
        timeReveal: timeReveal,
        bubbleFrames: bubbleFrames
      ),
      onReachTop: loadOlder,
      onBottomChange: { bottom in
        atBottom = bottom
        if bottom, let last = items.lastMessageSeq { bottomMark = max(bottomMark, last) }
        markReadIfNeeded()
        if bottom { trimIfStillAtBottom() }
      },
      onVisibleSeqs: { visible in mentionsSeen(visible) },
      onScrollDate: { time in showScrollDay(time) },
      scrollRequest: scrollRequest
    )
    // 往上翻时顶部的日期（今天 / 昨天 / 日期），透明玻璃徽章；在向服务端要更早的消息时显示加载中。
    .overlay(alignment: .top) {
      if fetchingOlder, notice == nil {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("正在加载更早的消息").font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
        .padding(.top, 6)
        .transition(.opacity)
        .allowsHitTesting(false)
      } else if let scrollDay, notice == nil {
        Text(scrollDay)
          .font(.footnote.weight(.medium))
          .padding(.horizontal, 12)
          .padding(.vertical, 5)
          .glassEffect(.clear, in: Capsule())
          .padding(.top, 6)
          .transition(.opacity)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.2), value: scrollDay)
    .overlay(alignment: .top) {
      if let notice {
        Text(notice)
          .font(.footnote)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .glassEffect(.regular, in: Capsule())
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: notice)
    // 两个按钮的位置是固定的：回到底部按钮不显示时也留着它的位置，"有人@我"不会因为它出现而被顶上去。
    .overlay(alignment: .bottomTrailing) {
      VStack(spacing: 12) {
        if let top = mentions.first {
          FloatingChatButton(systemImage: Self.icon(top.kind), count: mentions.count) { jumpToNextMention() }
            .contextMenu {
              Button("全部标为已看（\(mentions.count) 条）", systemImage: "checkmark.circle") {
                let all = Set(mentions.map(\.seq))
                mentions = []
                mentionsSeen(all, force: true)
              }
            }
            .transition(.scale.combined(with: .opacity))
        }
        ZStack {
          if !atBottom {
            FloatingChatButton(systemImage: "chevron.down", count: newMessageCount) {
              bottomMark = items.lastMessageSeq ?? bottomMark
              scrollRequest = ChatScrollRequest(target: .bottom)
            }
            .transition(.scale.combined(with: .opacity))
          }
        }
        .frame(width: 46, height: 46)
      }
      .padding(.trailing, 14)
      .padding(.bottom, 10)
      .animation(.snappy, value: atBottom)
      .animation(.snappy, value: mentions.count)
    }
    // 拖进来的照片、视频、文件：松手直接发送。
    .dropDestination(for: DroppedItem.self) { items, _ in
      Task {
        for item in items { if let a = await AttachmentLoader.load(file: item.url) { composer.attachments.append(a) } }
        sendAll()
      }
      return !items.isEmpty
    } isTargeted: { dropTargeted = $0 }
    .overlay { if dropTargeted { DropHint().transition(.opacity) } }
    .animation(.easeOut(duration: 0.15), value: dropTargeted)
    .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkPasteboard() }
    .onChange(of: inputFocused) { _, focused in if focused { checkPasteboard() } }
    .safeAreaBar(edge: .bottom) {
      if selection.active { selectionBar } else { inputArea }
    }
    .sheet(item: $pendingForward) { pending in
      ChatPicker(session: session) { target in
        pendingForward = nil
        Task { await forward(pending, to: target) }
      }
    }
    .toolbar(.hidden, for: .tabBar)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Button { showInfo = true } label: {
          VStack(spacing: 0) {
            Text(title).font(.headline).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
          }
        }
        .buttonStyle(.plain)
      }
      ToolbarItem(placement: .topBarTrailing) {
        if selection.active {
          Button("取消") { selection.end() }
        } else {
          if let d = dialog {
            // 右上角显示对方 / 群的头像，点开是资料页 / 群资料。
            let known = peer.flatMap { $0.avatarSha256.isEmpty ? nil : $0.avatarSha256 }
            Button { showInfo = true } label: {
              AvatarView(sha256: known ?? (isGroup ? avatars.groupSha256[d.peerID] : avatars.sha256[d.peerID]), title: title, seed: d.peerID, size: 32)
                .onAppear {
                  guard known == nil else { return }
                  if isGroup { avatars.wantGroup(d.peerID, session: session) } else { avatars.want(d.peerID, session: session) }
                }
            }
            .accessibilityLabel(isGroup ? "群资料" : "资料")
          }
        }
      }
    }
    .navigationDestination(isPresented: $showInfo) {
      if isGroup, let dialog {
        GroupInfoView(session: session, dialog: dialog, members: members, avatars: avatars, onMention: { id in
          showInfo = false
          actions.mention(id)
        })
      } else if let dialog {
        UserProfileView(session: session, userId: dialog.peerID, groupMember: nil)
      }
    }
    .sheet(item: $profileUser) { target in
      NavigationStack {
        UserProfileView(session: session, userId: target.userId, groupMember: members.byId[target.userId], onMention: isGroup ? {
          profileUser = nil
          actions.mention(target.userId)
        } : nil, viaGroupId: isGroup ? (dialog?.peerID ?? 0) : 0)
      }
      .presentationDetents([.medium, .large])
    }
    .mediaViewer(item: $mediaTarget, session: session, chatId: chatId)
    .quickLookPreview($fileURL)
    .sheet(item: $forwardMessage) { m in
      NavigationStack { ForwardView(session: session, chatId: chatId, seq: m.seq, path: []) }
    }
    .sheet(isPresented: $composer.pickingMention) {
      MentionPicker(members: members, avatars: avatars, session: session) { picked in
        composer.pickingMention = false
        if let picked {
          if picked.userId == 0 { composer.mentionAll() } else { composer.insertMention(userId: picked.userId, name: picked.name, replacingTrailingAt: true) }
        }
        inputFocused = true
      }
      .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showStickers) {
      StickerPanel(session: session, onPick: { sticker in
        showStickers = false
        sendSticker(sticker)
      }, onFace: { id, name in composer.insertFace(id: id, name: name) })
      .presentationDetents([.medium, .large])
    }
    .task { await open() }
    .onAppear { model.openChatId = chatId }
    #if DEBUG
    .task { if VoiceRecorder.holdFakeRecording { try? await recorder.start() } }
    #endif
    .task(id: limit) {
      do {
        for try await list in session.store.observeChat(chatId: chatId, limit: limit) {
          items = list
          lookup.update(list)
          itemsVersion += 1
          noteNewMessages()
          markReadIfNeeded()
        }
      } catch {}
    }
    .task {
      guard let d = try? session.store.dialog(chatId: chatId) else { return }
      do {
        for try await p in session.store.observePeer(for: d) { peer = p }
      } catch {}
    }
    .onChange(of: composer.text) { old, new in
      composer.textChanged(from: old, to: new)
      // 群里输入 "@"：弹出选人。
      if isGroup, new.hasSuffix("@"), new.count == old.count + 1 { composer.pickingMention = true }
      // 删掉了的 "@名字" / "[表情]"：发送时找不到就当没有（见 Composer.segments）。
    }
    // 一次最多选 20 张 / 个，按选择的顺序逐条发出。
    .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
    .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      Task { for url in urls { if let a = await AttachmentLoader.load(file: url) { composer.attachments.append(a) } } }
    }
    .onChange(of: photoItems) { _, items in
      guard !items.isEmpty else { return }
      photoItems = []
      // 选好的先放进输入框上方，点发送才发。
      Task { for item in items { if let a = await AttachmentLoader.load(item) { composer.attachments.append(a) } } }
    }
    .onDisappear {
      if model.openChatId == chatId { model.openChatId = nil }
      voice.stop()
      Task { await setActive(false) }
    }
    .confirmationDialog(
      "以群管理身份撤回这条消息？群里所有人都会看到它被撤回。",
      isPresented: Binding(get: { confirmRecall != nil }, set: { if !$0 { confirmRecall = nil } }),
      titleVisibility: .visible,
      presenting: confirmRecall
    ) { m in
      Button("撤回", role: .destructive) { recall(m) }
    }
    .alert("发送失败", isPresented: .constant(sendError != nil), presenting: sendError) { _ in
      Button("好") { sendError = nil }
    } message: { Text($0) }
  }

  private var subtitle: String? {
    if model.isTyping(chatId) { return "正在输入…" }
    if isGroup, let count = peer?.memberCount, count > 0 { return "\(count) 人" }
    return nil
  }

  // MARK: 多选

  private var selectionBar: some View {
    HStack(spacing: 10) {
      Text("已选 \(selection.seqs.count) 条").font(.subheadline).foregroundStyle(.secondary)
      Spacer()
      Button("逐条转发", systemImage: "arrowshape.turn.up.right") {
        pendingForward = PendingForward(seqs: selection.seqs.sorted(), bundle: false)
      }
      .buttonStyle(.glass)
      Button("合并转发", systemImage: "tray.full") {
        pendingForward = PendingForward(seqs: selection.seqs.sorted(), bundle: true)
      }
      .buttonStyle(.glassProminent)
    }
    .disabled(selection.seqs.isEmpty)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func forward(_ pending: PendingForward, to target: Int64) async {
    var req = Qqbridge_V1_ForwardMessagesRequest()
    req.fromChatID = chatId
    req.seqs = pending.seqs
    req.toChatIds = [target]
    req.bundle = pending.bundle
    do {
      let res = try await session.api.messages.forwardMessages(request: req, headers: session.api.headers).get()
      for entry in res.entries { try? session.store.upsertLocalOutbox(entry) }
      selection.end()
    } catch {
      sendError = "转发失败：\(error)"
    }
  }

  // MARK: 输入区

  private var inputArea: some View {
    VStack(spacing: 6) {
      if let up = uploading {
        HStack(spacing: 8) {
          ProgressView(value: up.progress).frame(width: 80)
          Text("正在上传 \(up.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
          Spacer()
        }
        .padding(.horizontal, 16)
      }
      if !composer.attachments.isEmpty {
        AttachmentTray(composer: composer)
      }
      if canPaste, inputFocused, composer.attachments.isEmpty {
        Button {
          if let a = AttachmentLoader.fromPasteboard() { composer.attachments.append(a) }
          canPaste = false
        } label: {
          Label("粘贴图片", systemImage: "doc.on.clipboard").font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
      }
      if let reply = composer.replyTo {
        HStack(spacing: 8) {
          Rectangle().fill(.tint).frame(width: 3)
          VStack(alignment: .leading, spacing: 1) {
            Text("回复 \(name(of: reply.senderID))").font(.caption.bold())
            Text(Format.preview(reply)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button { composer.replyTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
      }
      HStack(alignment: .bottom, spacing: 6) {
        if recorder.recording {
          RecordingBar(recorder: recorder)
        } else {
          // 左：附件（和 Telegram 一样是图标，不占大圆按钮）。
          Menu {
            // PhotosPicker 直接放进 Menu 不会弹出，改由按钮打开。
            Button("照片或视频", systemImage: "photo.on.rectangle") { showPhotos = true }
            Button("文件", systemImage: "doc") { showFiles = true }
            if isGroup { Button("@某人", systemImage: "at") { composer.text += "@" } }
          } label: {
            Image(systemName: "paperclip").font(.title3).frame(width: 36, height: 40)
          }
          .tint(.secondary)
          // 中：输入框占满，右侧嵌着表情按钮。
          HStack(alignment: .bottom, spacing: 4) {
            TextField("消息", text: $composer.text, axis: .vertical)
              .lineLimit(1...6)
              .focused($inputFocused)
              .padding(.vertical, 10)
            Button { showStickers = true } label: {
              Image(systemName: "face.smiling").font(.title3).foregroundStyle(.secondary).frame(width: 30, height: 40)
            }
          }
          .padding(.leading, 14)
          .padding(.trailing, 6)
          .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        // 右：有字时发送，没字时按住录语音。
        if hasText, !recorder.recording {
          Button(action: sendAll) {
            Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
              .frame(width: 34, height: 34)
              .background(Circle().fill(Color.accentColor))
          }
          .buttonStyle(.plain)
          .frame(width: 36, height: 40)
        } else {
          MicButton(recorder: recorder, onStart: startRecording, onFinish: finishRecording)
        }
      }
      .padding(.horizontal, 12)
    }
    .padding(.vertical, 8)
  }

  // MARK: 打开与已读

  private func open() async {
    dialog = try? session.store.dialog(chatId: chatId)
    if let d = dialog {
      selfUin = (try? session.store.selfUin(qqAccountId: d.qqAccountID)) ?? 0
      lookup.attach(session.store, qqAccountId: d.qqAccountID)
    }
    wireActions()
    // 已读位置要在标已读之前记下来：之后的 @我 / 回复我 / @全体成员 就是要提示的。
    if let d = dialog {
      let pending = d.unreadMentions + d.unreadReplies + (d.mentionAllNotify ? d.unreadMentionAll : 0)
      if pending > 0 { Task { await loadMentions(after: d.readInboxMaxSeq, includeAll: d.mentionAllNotify) } }
    }
    async let catchUp: Void = { try? await session.sync.openChat(chatId) }()
    async let active: Void = setActive(true)
    if let d = dialog, d.scene == .group { await members.load(session: session, groupId: d.peerID) }
    _ = await (catchUp, active)
    markReadIfNeeded()
  }

  // MARK: 有人@我、回到底部

  private var newMessageCount: Int {
    items.reduce(0) { n, item in
      if case .message(let m) = item, m.seq > bottomMark, m.senderID != selfUin { return n + 1 }
      return n
    }
  }

  static func icon(_ kind: MentionTarget.Kind) -> String {
    switch kind {
    case .reply: "arrowshape.turn.up.left.fill"
    case .me: "at"
    case .all: "megaphone.fill"
    }
  }

  private func loadMentions(after seq: Int64, includeAll: Bool) async {
    var req = Qqbridge_V1_ListUnreadMentionsRequest()
    req.chatID = chatId
    req.afterSeq = seq
    guard let res = try? await session.api.messages.listUnreadMentions(request: req, headers: session.api.headers).get() else { return }
    let found = res.mentions.compactMap { MentionTarget(seq: $0.seq, flags: $0.flags, includeAll: includeAll) }
    // 和打开后新来的合在一起，最新的在最前。
    let known = Set(mentions.map(\.seq))
    mentions = (mentions + found.filter { !known.contains($0.seq) }).sorted { $0.seq > $1.seq }
  }

  /// 新到的消息：不在底部时，里面的 @我 / 回复我 / @全体成员 加进"有人@我"（最新的在最前）。
  private func noteNewMessages() {
    guard let last = items.lastMessageSeq else { return }
    if newestSeen == 0 {
      newestSeen = last
      if bottomMark == 0 { bottomMark = last }
      return
    }
    guard last > newestSeen else { return }
    let includeAll = dialog?.mentionAllNotify ?? true
    if !atBottom {
      let fresh = items.compactMap { item -> MentionTarget? in
        guard case .message(let m) = item, m.seq > newestSeen, m.senderID != selfUin, m.state != .recalled else { return nil }
        return MentionTarget(seq: m.seq, flags: m.flags, includeAll: includeAll)
      }
      mentions = (fresh + mentions).sorted { $0.seq > $1.seq }
    } else {
      bottomMark = last
    }
    newestSeen = last
  }

  private func jumpToNextMention() {
    guard let target = mentions.first else { return }
    mentions.removeFirst()
    mentionsSeen([target.seq], force: true)
    Task { await jump(to: target.seq) }
  }

  /// 看到了的 @：从"有人@我"里移掉，并告诉服务端（不再算未读 @，已读位置不动）。
  /// force：不管在不在屏幕上（点按钮跳过去、全部标为已看）。
  private func mentionsSeen(_ seqs: Set<Int64>, force: Bool = false) {
    let hits = force ? seqs : Set(mentions.map(\.seq)).intersection(seqs)
    if !force { mentions.removeAll { hits.contains($0.seq) } }
    let fresh = hits.subtracting(seenMentions)
    guard !fresh.isEmpty else { return }
    seenMentions.formUnion(fresh)
    var req = Qqbridge_V1_MarkMentionsSeenRequest()
    req.chatID = chatId
    req.seqs = Array(fresh)
    Task { _ = await session.api.messages.markMentionsSeen(request: req, headers: session.api.headers) }
  }

  /// 只看剪贴板里有没有图片（不读内容，不会弹出"允许粘贴"）。
  private func checkPasteboard() {
    let pb = UIPasteboard.general
    canPaste = pb.hasImages || pb.contains(pasteboardTypes: [MediaPasteboard.type])
  }

  private func showScrollDay(_ time: Int64?) {
    scrollDayHide?.cancel()
    if let time {
      let day = Format.dayBadge(time)
      if day != scrollDay { scrollDay = day }
    } else {
      scrollDayHide = Task {
        try? await Task.sleep(for: .seconds(1.2))
        if !Task.isCancelled { scrollDay = nil }
      }
    }
  }

  private func copyMedia(_ media: Qqbridge_V1_MediaInfo, sticker: Bool) async {
    let sha = media.state == .stored && !media.sha256.isEmpty ? media.sha256 : (media.thumbSha256.isEmpty ? nil : media.thumbSha256)
    guard let sha, let file = try? await session.media.file(for: sha, chatId: chatId), let data = try? Data(contentsOf: file) else {
      show("图片还没下载好")
      return
    }
    var item: [String: Any] = [MediaPasteboard.type: (try? JSONEncoder().encode(MediaPasteboard.Payload(sha256: sha, sticker: sticker))) ?? Data()]
    if data.starts(with: [0x47, 0x49, 0x46]) {
      item[UTType.gif.identifier] = data
    } else if let image = UIImage(data: data), let png = image.pngData() {
      item[UTType.png.identifier] = png
    }
    UIPasteboard.general.setItems([item])
    show("已复制")
  }

  /// 加到"我的表情"：原图还没下载就先让服务端从 QQ 拉。
  private func addSticker(_ media: Qqbridge_V1_MediaInfo, seq: Int64) async {
    var sha = media.state == .stored ? media.sha256 : ""
    if sha.isEmpty {
      var ref = Qqbridge_V1_MediaRef()
      ref.chatID = chatId
      ref.seq = seq
      ref.ord = media.ord
      var req = Qqbridge_V1_RequestMediaRequest()
      req.refs = [ref]
      req.original = true
      let res = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get()
      sha = res?.media.first.flatMap { $0.state == .stored ? $0.sha256 : nil } ?? ""
    }
    guard !sha.isEmpty else {
      show("这张图已经拿不到了")
      return
    }
    var req = Qqbridge_V1_AddStickerRequest()
    req.sha256 = sha
    do {
      _ = try await session.api.media.addSticker(request: req, headers: session.api.headers).get()
      show("已添加到我的表情")
    } catch {
      show("添加失败：\(LoadState.describe(error))")
    }
  }

  private func show(_ text: String) {
    notice = text
    Task {
      try? await Task.sleep(for: .seconds(2))
      if notice == text { notice = nil }
    }
  }

  /// 回到底部、停了一会儿：把翻页时加载的大量旧消息收回到最近一屏，免得列表越翻越重。
  private func trimIfStillAtBottom() {
    guard limit > 120 else { return }
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard atBottom else { return }
      limit = 60
      reachedStart = false
    }
  }

  /// 跳到某条消息：本地还没加载到它就往前翻页，再把列表放大到包含它，最后滚过去并高亮。
  private func jump(to seq: Int64) async {
    var guardPages = 0
    while let first = items.firstMessageSeq, first > seq, !reachedStart, guardPages < 20 {
      let window = try? session.store.loadedWindow(chatId: chatId)
      let need = (try? session.store.messageCount(chatId: chatId, fromSeq: seq)) ?? 0
      if let window, seq >= window.floor, need >= limit {
        // 已经在连续区间里了，只是列表没显示那么多。
        limit = need + 20
      } else {
        let got = (try? await session.sync.loadOlder(chatId, limit: 100)) ?? 0
        if got == 0 { reachedStart = true }
        limit += got
      }
      guardPages += 1
      // 等列表按新的 limit 刷新。
      for _ in 0..<20 where (items.firstMessageSeq ?? 0) > seq { try? await Task.sleep(for: .milliseconds(50)) }
    }
    // 那条没加载出来（例如中间有缺口）就不滚，免得请求一直挂着、新消息也不跟着滚到底。
    guard items.contains(where: { if case .message(let m) = $0 { m.seq == seq } else { false } }) else {
      show("这条消息加载不到（可能已过期或还没同步）")
      return
    }
    scrollRequest = ChatScrollRequest(target: .item("m\(seq)"))
    highlight.flash(seq)
  }

  /// 看到最底部了：标已读到最后一条消息（同一位置只标一次）。
  private func markReadIfNeeded() {
    guard atBottom, let last = items.lastMessageSeq, last > lastMarked else { return }
    guard (dialog?.unreadCount ?? 1) > 0 || last > (dialog?.readInboxMaxSeq ?? 0) else { return }
    lastMarked = last
    Task { _ = try? await session.api.markRead(chatId: chatId, maxSeq: last) }
  }

  private func wireActions() {
    actions.reply = { m in
      composer.replyTo = m
      inputFocused = true
    }
    actions.mention = { userId in
      composer.insertMention(userId: userId, name: name(of: userId))
      inputFocused = true
    }
    actions.showProfile = { profileUser = ProfileTarget(userId: $0) }
    actions.react = { m, emoji in
      Task {
        var req = Qqbridge_V1_ReactRequest()
        req.chatID = chatId
        req.seq = m.seq
        req.emojiID = emoji
        req.add = !m.reactions.contains { $0.emojiID == emoji && $0.me }
        if let res = try? await session.api.messages.react(request: req, headers: session.api.headers).get() {
          try? session.store.applyChat(chatId: chatId, messages: [res.message], events: [], newChatPts: nil)
        }
      }
    }
    actions.recall = { m in
      // 普通撤回直接撤；用群主 / 管理员权限撤回的（别人的，或自己超过 2 分钟的）先确认。
      if Date().timeIntervalSince1970 - Double(m.time) < 120, m.senderID == selfUin { recall(m) } else { confirmRecall = m }
    }
    actions.openMedia = { mediaTarget = $0 }
    actions.jumpTo = { seq in Task { await jump(to: seq) } }
    actions.copyMedia = { media, sticker in Task { await copyMedia(media, sticker: sticker) } }
    actions.addSticker = { media, seq in Task { await addSticker(media, seq: seq) } }
    actions.forward = { m in pendingForward = PendingForward(seqs: [m.seq], bundle: false) }
    actions.openFile = { file in
      Task {
        // 原件可能已清理（按需会话），下载接口会当场从 QQ 拉回；拿不到就提示。
        do {
          let cached = try await session.media.file(for: file.media.sha256, chatId: chatId)
          let named = FileManager.default.temporaryDirectory.appendingPathComponent(file.name.isEmpty ? cached.lastPathComponent : file.name)
          try? FileManager.default.removeItem(at: named)
          try FileManager.default.copyItem(at: cached, to: named)
          fileURL = named
        } catch {
          sendError = "文件打不开：QQ 上已经拿不到了"
        }
      }
    }
    actions.playVoice = { voice.toggle($0, session: session) }
    actions.openForward = { forwardMessage = $0 }
  }

  private func name(of userId: Int64) -> String {
    if userId == selfUin { return "我" }
    return members.displayName(userId) ?? (try? session.store.userName(qqAccountId: dialog?.qqAccountID ?? 0, userId: userId)) ?? String(userId)
  }

  // MARK: 发送

  private var hasText: Bool { !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.attachments.isEmpty }

  private func startRecording() {
    recorder.onAutoFinish = { finishRecording(cancelled: false) }
    Task {
      do {
        try await recorder.start()
      } catch {
        sendError = (error as? VoiceRecorder.StartError) == .denied ? "没有麦克风权限：请在系统设置里允许 BetterChat 使用麦克风" : "录不了音：没有找到可用的麦克风"
      }
    }
  }

  private func finishRecording(cancelled: Bool) {
    if cancelled || recorder.willCancel {
      recorder.cancel()
      return
    }
    guard let (url, duration) = recorder.finish() else { return }
    Task {
      defer { try? FileManager.default.removeItem(at: url) }
      do {
        let data = try Data(contentsOf: url)
        let uploaded = try await session.api.upload(data, mime: "audio/mp4", name: "voice.m4a")
        var seg = Qqbridge_V1_OutgoingSegment()
        seg.record.sha256 = uploaded.sha256
        seg.record.durationSec = UInt32(duration.rounded())
        try await session.sender.send(chatId: chatId, segments: [seg])
      } catch {
        sendError = "语音发送失败：\(error)"
      }
    }
  }

  /// 点发送：先把附件逐个上传、发出（每个一条；第一条带回复），再发文字。
  private func sendAll() {
    let pending = composer.attachments.filter { if case .uploading = $0.state { false } else { true } }
    guard !pending.isEmpty else {
      sendText()
      return
    }
    var reply = composer.replyTo?.seq
    let hasWords = !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    Task {
      for a in pending {
        if await send(a, replyTo: reply) { reply = nil }
      }
      if hasWords {
        if reply == nil { composer.replyTo = nil }
        sendText()
      } else if reply == nil {
        composer.replyTo = nil
      }
    }
  }

  /// 上传并发出一个附件；成功后从预览条移除。
  private func send(_ a: Attachment, replyTo: Int64?) async -> Bool {
    composer.update(a.id, .uploading(0))
    let progress: @Sendable (Double) -> Void = { p in Task { @MainActor in composer.update(a.id, .uploading(p)) } }
    do {
      var seg = Qqbridge_V1_OutgoingSegment()
      var reply = replyTo
      switch a.payload {
      case .image(let data):
        let isGif = data.starts(with: [0x47, 0x49, 0x46])
        let uploaded = try await session.api.upload(data, mime: isGif ? "image/gif" : "image/jpeg", name: isGif ? "image.gif" : "photo.jpg")
        seg.image.sha256 = uploaded.sha256
      case .stored(let sha, let sticker):
        seg.image.sha256 = sha
        if sticker {
          seg.image.sticker = true
          seg.image.summary = "[动画表情]"
        }
      case .video(let url):
        let uploaded = try await session.api.uploadFile(at: url, mime: "video/mp4", name: url.lastPathComponent, progress: progress)
        seg.video.sha256 = uploaded.sha256
        reply = nil  // 视频、文件不能带回复
      case .file(let url, let name):
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let uploaded = try await session.api.uploadFile(at: url, mime: mime, name: name, progress: progress)
        seg.file.sha256 = uploaded.sha256
        seg.file.name = name
        reply = nil
      }
      try await session.sender.send(chatId: chatId, segments: [seg], replyToSeq: reply)
      composer.attachments.removeAll { $0.id == a.id }
      return reply != nil
    } catch {
      composer.update(a.id, .failed("\(error)"))
      sendError = "发送失败：\(LoadState.describe(error))"
      return false
    }
  }

  private func sendText() {
    let segments = composer.segments()
    guard !segments.isEmpty else { return }
    let reply = composer.replyTo?.seq
    let sentText = composer.text
    composer.reset()
    // 中文输入法还有没上屏的候选字时，清空后输入法会把字再提交回来：内容还是刚发出去的那段就再清一次。
    Task {
      for delay in [50, 200] {
        try? await Task.sleep(for: .milliseconds(delay))
        if !sentText.isEmpty, composer.text == sentText || sentText.hasPrefix(composer.text) && !composer.text.isEmpty { composer.text = "" }
      }
    }
    Task {
      do {
        try await session.sender.send(chatId: chatId, segments: segments, replyToSeq: reply)
      } catch {
        sendError = "\(error)"
      }
    }
  }

  /// 发文件：按块上传（任意大小），再作为 QQ 文件发出（语音、视频、文件都要单独成条，不能带回复）。
  private func sendFile(_ url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let name = url.lastPathComponent
    uploading = (name, 0)
    defer { uploading = nil }
    do {
      let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      let uploaded = try await session.api.uploadFile(at: url, mime: mime, name: name) { p in
        Task { @MainActor in uploading = (name, p) }
      }
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.file.sha256 = uploaded.sha256
      seg.file.name = name
      try await session.sender.send(chatId: chatId, segments: [seg])
    } catch {
      sendError = "文件发送失败：\(error)"
    }
  }

  private func sendVideo(_ item: PhotosPickerItem) async {
    uploading = ("视频", 0)
    defer { uploading = nil }
    do {
      guard let movie = try await item.loadTransferable(type: MovieFile.self) else { return }
      defer { try? FileManager.default.removeItem(at: movie.url) }
      let uploaded = try await session.api.uploadFile(at: movie.url, mime: "video/mp4", name: movie.url.lastPathComponent) { p in
        Task { @MainActor in uploading = ("视频", p) }
      }
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.video.sha256 = uploaded.sha256
      try await session.sender.send(chatId: chatId, segments: [seg])
    } catch {
      sendError = "视频发送失败：\(error)"
    }
  }

  private func recall(_ m: Qqbridge_V1_Message) {
    Task {
      var req = Qqbridge_V1_RecallMessageRequest()
      req.chatID = chatId
      req.seq = m.seq
      do {
        _ = try await session.api.messages.recallMessage(request: req, headers: session.api.headers).get()
      } catch {
        sendError = "撤回失败：\(LoadState.describe(error))"
      }
    }
  }

  private func sendPhoto(_ item: PhotosPickerItem) async {
    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
      await sendVideo(item)
      return
    }
    do {
      guard let raw = try await item.loadTransferable(type: Data.self), let image = UIImage(data: raw) else { return }
      // 统一转成 JPEG（HEIC 等 QQ 未必认），长边不超过 2560。
      let data = Self.jpeg(image) ?? raw
      let uploaded = try await session.api.upload(data, mime: "image/jpeg", name: "photo.jpg")
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.image.sha256 = uploaded.sha256
      try await session.sender.send(chatId: chatId, segments: [seg], replyToSeq: composer.replyTo?.seq)
      composer.replyTo = nil
    } catch {
      sendError = "图片发送失败：\(error)"
    }
  }

  private func sendSticker(_ sticker: Qqbridge_V1_Sticker) {
    guard !sticker.sha256.isEmpty else { return }
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.image.sha256 = sticker.sha256
    seg.image.sticker = true
    seg.image.summary = sticker.desc.isEmpty ? "[动画表情]" : sticker.desc
    Task {
      do { try await session.sender.send(chatId: chatId, segments: [seg]) } catch { sendError = "\(error)" }
    }
  }

  nonisolated static func jpeg(_ image: UIImage) -> Data? {
    let maxSide: CGFloat = 2560
    let scale = min(1, maxSide / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.jpegData(withCompressionQuality: 0.85) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
  }

  // MARK: 翻页

  /// 往上翻页：本地还有更早的就先放宽窗口，没有了再向服务端要（服务端没有的会现场向 QQ 拉）。
  private func loadOlder() {
    guard !loadingOlder, !reachedStart else { return }
    loadingOlder = true
    Task {
      defer { loadingOlder = false }
      // 连续区间里本地还有没显示的：先放大显示范围；都显示了才向服务端要更早的。
      let localCount = (try? session.store.loadedWindow(chatId: chatId).count) ?? 0
      if localCount > limit {
        limit += 60
        return
      }
      fetchingOlder = true
      defer { fetchingOlder = false }
      let got = (try? await session.sync.loadOlder(chatId, limit: 60)) ?? 0
      if got == 0 { reachedStart = true } else { limit += got }
    }
  }

  /// 告诉服务端正在看哪个会话：它的媒体优先下载，头像按需刷新。
  private func setActive(_ active: Bool) async {
    var req = Qqbridge_V1_SetActiveChatRequest()
    req.chatID = active ? chatId : 0
    _ = await session.api.dialogs.setActiveChat(request: req, headers: session.api.headers)
  }
}

struct ProfileTarget: Identifiable {
  let userId: Int64
  var id: Int64 { userId }
}

extension Qqbridge_V1_Message: @retroactive Identifiable {
  public var id: String { "\(chatID):\(seq)" }
}

extension [ChatItem] {
  var lastMessageSeq: Int64? {
    for item in reversed() { if case .message(let m) = item { return m.seq } }
    return nil
  }

  var firstMessageSeq: Int64? {
    for item in self { if case .message(let m) = item { return m.seq } }
    return nil
  }
}

struct PendingForward: Identifiable {
  let seqs: [Int64]
  let bundle: Bool
  var id: String { "\(bundle):\(seqs)" }
}

/// 相册里的视频：拷到临时目录再传（系统给的文件在回调结束后会被删）。
struct MovieFile: Transferable {
  let url: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { movie in SentTransferredFile(movie.url) } importing: { received in
      let dest = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)")
      try FileManager.default.copyItem(at: received.file, to: dest)
      return MovieFile(url: dest)
    }
  }
}

/// 聊天页右下角的圆形玻璃按钮，右上角带个蓝色数字。
struct FloatingChatButton: View {
  let systemImage: String
  let count: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 46, height: 46)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.tint)
    .glassEffect(.regular.interactive(), in: Circle())
    .overlay(alignment: .topTrailing) {
      if count > 0 {
        Text(count > 99 ? "99+" : "\(count)")
          .font(.caption2.bold().monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 5)
          .frame(minWidth: 18, minHeight: 18)
          .background(Color.accentColor, in: Capsule())
          .offset(x: 6, y: -6)
      }
    }
  }
}

/// 拖进来的东西：先落到临时文件再处理。
struct DroppedItem: Transferable {
  let url: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .item) { received in
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let dest = dir.appendingPathComponent(received.file.lastPathComponent)
      try FileManager.default.copyItem(at: received.file, to: dest)
      return DroppedItem(url: dest)
    }
  }
}
