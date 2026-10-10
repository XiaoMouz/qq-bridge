// 聊天页：消息列表（UIKit 集合视图，见 ChatCollectionView）+ 玻璃输入栏。
// 数据流：打开时让同步引擎拉首屏 / 补变化 → 观察本地库 → 列表刷新；滑到顶部时往上翻页；看到底部就标已读。
import PhotosUI
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
  @State private var reachedStart = false
  @State private var composer = Composer()
  @State private var members = GroupMembers()
  @State private var avatars = AvatarBook()
  @State private var voice = VoicePlayer()
  @State private var actions = ChatActions()
  @State private var sendError: String?
  @State private var profileUser: ProfileTarget?
  @State private var mediaTarget: MediaTarget?
  @State private var forwardMessage: Qqbridge_V1_Message?
  @State private var showInfo = false
  @State private var showStickers = false
  @State private var photoItem: PhotosPickerItem?
  @State private var showPhotos = false
  @State private var atBottom = true
  @State private var lastMarked: Int64 = 0
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
      context: MessageContext(
        selfUin: selfUin,
        isGroup: isGroup,
        qqAccountId: dialog?.qqAccountID ?? 0,
        chatId: chatId,
        store: session.store,
        members: members,
        avatars: avatars,
        voice: voice,
        actions: actions,
        session: session
      ),
      onReachTop: loadOlder,
      onBottomChange: { atBottom = $0; markReadIfNeeded() }
    )
    .safeAreaBar(edge: .bottom) { inputArea }
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
        Button("详情", systemImage: isGroup ? "person.3" : "person.crop.circle") { showInfo = true }
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
        } : nil)
      }
      .presentationDetents([.medium, .large])
    }
    .fullScreenCover(item: $mediaTarget) { MediaViewer(target: $0, session: session, chatId: chatId) }
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
      StickerPanel(session: session) { sticker in
        showStickers = false
        sendSticker(sticker)
      }
      .presentationDetents([.medium, .large])
    }
    .task { await open() }
    .task(id: limit) {
      do {
        for try await list in session.store.observeChat(chatId: chatId, limit: limit) {
          items = list
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
      // 群里输入 "@"：弹出选人。
      if isGroup, new.hasSuffix("@"), new.count == old.count + 1 { composer.pickingMention = true }
      // 删掉了某个 "@名字"：对应的 @ 也不要了。
      composer.mentions.removeAll { !new.contains("@\($0.name)") }
    }
    .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      photoItem = nil
      Task { await sendPhoto(item) }
    }
    .onDisappear {
      voice.stop()
      Task { await setActive(false) }
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

  // MARK: 输入区

  private var inputArea: some View {
    VStack(spacing: 6) {
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
      HStack(alignment: .bottom, spacing: 8) {
        Menu {
          // PhotosPicker 直接放进 Menu 不会弹出，改由按钮打开。
          Button("照片", systemImage: "photo") { showPhotos = true }
          Button("表情", systemImage: "face.smiling") { showStickers = true }
          if isGroup { Button("@某人", systemImage: "at") { composer.text += "@" } }
        } label: {
          Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 40, height: 40)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        TextField("消息", text: $composer.text, axis: .vertical)
          .lineLimit(1...6)
          .focused($inputFocused)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        Button(action: sendText) {
          Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 40, height: 40)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .disabled(composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.horizontal, 12)
    }
    .padding(.vertical, 8)
  }

  // MARK: 打开与已读

  private func open() async {
    dialog = try? session.store.dialog(chatId: chatId)
    if let d = dialog { selfUin = (try? session.store.selfUin(qqAccountId: d.qqAccountID)) ?? 0 }
    wireActions()
    async let catchUp: Void = { try? await session.sync.openChat(chatId) }()
    async let active: Void = setActive(true)
    if let d = dialog, d.scene == .group { await members.load(session: session, groupId: d.peerID) }
    _ = await (catchUp, active)
    markReadIfNeeded()
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
      Task {
        var req = Qqbridge_V1_RecallMessageRequest()
        req.chatID = chatId
        req.seq = m.seq
        do { _ = try await session.api.messages.recallMessage(request: req, headers: session.api.headers).get() } catch { sendError = "撤回失败：\(error)" }
      }
    }
    actions.openMedia = { mediaTarget = $0 }
    actions.playVoice = { voice.toggle($0, session: session) }
    actions.openForward = { forwardMessage = $0 }
  }

  private func name(of userId: Int64) -> String {
    if userId == selfUin { return "我" }
    return members.displayName(userId) ?? (try? session.store.userName(qqAccountId: dialog?.qqAccountID ?? 0, userId: userId)) ?? String(userId)
  }

  // MARK: 发送

  private func sendText() {
    let segments = composer.segments()
    guard !segments.isEmpty else { return }
    let reply = composer.replyTo?.seq
    composer.reset()
    Task {
      do {
        try await session.sender.send(chatId: chatId, segments: segments, replyToSeq: reply)
      } catch {
        sendError = "\(error)"
      }
    }
  }

  private func sendPhoto(_ item: PhotosPickerItem) async {
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

  static func jpeg(_ image: UIImage) -> Data? {
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
      let localCount = (try? session.store.messages(chatId: chatId, limit: limit + 1).count) ?? 0
      if localCount > limit {
        limit += 60
        return
      }
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
}
