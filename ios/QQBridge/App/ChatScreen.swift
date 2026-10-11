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
  @State private var reachedStart = false
  @State private var composer = Composer()
  @State private var members = GroupMembers()
  @State private var avatars = AvatarBook()
  @State private var requester = MediaRequester()
  @State private var selection = MessageSelection()
  /// 要转发的消息和方式（选好会话后发给服务端）。
  @State private var pendingForward: PendingForward?
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
  @State private var photoItem: PhotosPickerItem?
  @State private var showPhotos = false
  @State private var showFiles = false
  /// 正在上传的附件：名字和进度（0…1）。
  @State private var uploading: (name: String, progress: Double)?
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
        requester: requester,
        selection: selection,
        voice: voice,
        actions: actions,
        session: session
      ),
      onReachTop: loadOlder,
      onBottomChange: { atBottom = $0; markReadIfNeeded() }
    )
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
          Button("详情", systemImage: isGroup ? "person.3" : "person.crop.circle") { showInfo = true }
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
        } : nil)
      }
      .presentationDetents([.medium, .large])
    }
    .fullScreenCover(item: $mediaTarget) { MediaViewer(target: $0, session: session, chatId: chatId) }
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
      // 删掉了的 "@名字" / "[表情]"：发送时找不到就当没有（见 Composer.segments）。
    }
    .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .any(of: [.images, .videos]))
    .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      Task { for url in urls { await sendFile(url) } }
    }
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      photoItem = nil
      Task { await sendPhoto(item) }
    }
    .onDisappear {
      if model.openChatId == chatId { model.openChatId = nil }
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
          Button(action: sendText) {
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

  private var hasText: Bool { !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  private func startRecording() {
    recorder.onAutoFinish = { finishRecording(cancelled: false) }
    Task {
      do {
        try await recorder.start()
      } catch {
        sendError = (error as? VoiceRecorder.StartError) == .denied ? "没有麦克风权限：请在系统设置里允许 QQ Bridge 使用麦克风" : "录不了音：没有找到可用的麦克风"
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
