// 大图 / 视频查看、合并转发、表情面板、会话内搜索、共享媒体。
import AVKit
import QQBridgeKit
import QQBridgeProto
import SwiftUI

// MARK: - 大图与视频

@Observable @MainActor
final class VideoPreviewModel {
  private(set) var player: AVPlayer?
  #if targetEnvironment(macCatalyst)
  let videoPlayback = VideoPlayback()
  #else
  let videoPlayback = VideoPlayback.shared
  #endif
  private var generation = 0

  func load(_ resolveURL: () async -> URL?) async {
    close()
    let request = generation
    let url = await resolveURL()
    // 关闭动画先于 SwiftUI task 取消；两者都必须阻止迟到的链接启动播放。
    guard request == generation, !Task.isCancelled, let url else { return }
    let player = AVPlayer(url: url)
    self.player = player
    player.play()
  }

  func close() {
    generation += 1
    videoPlayback.previewClosed(player)
    player = nil
  }
}

struct MediaViewer: View {
  let target: MediaTarget
  let session: Session
  let chatId: Int64
  @Environment(\.dismiss) private var dismiss
  #if targetEnvironment(macCatalyst)
  @Environment(\.macMediaWindow) private var mediaWindow
  #endif
  @State private var playback = VideoPreviewModel()
  /// 放不了时的说明（过期、下载失败）。
  @State private var videoMessage: String?
  @State private var fetching = false
  @State private var visible = false
  @State private var dragProgress: CGFloat = 0

  var body: some View {
    if target.kind == .image {
      ImageViewer(target: target, session: session, chatId: chatId, gallery: target.gallery)
    } else {
      videoBody
    }
  }

  private var videoBody: some View {
    ZStack {
      // 和看大图一样：压暗的毛玻璃背景，下拉时变淡。
      Rectangle()
        .fill(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .overlay(Color.black.opacity(0.6))
        .opacity(visible ? Double(1 - dragProgress * 0.9) : 0)
        .ignoresSafeArea()
      VStack(spacing: 8) {
        // 关闭按钮单独一行，不压在播放器自带的按钮（全屏、静音）上。
        if showsCloseButton { HStack {
          Spacer()
          Button(action: close) {
            Image(systemName: "xmark")
              .font(.system(size: 16, weight: .bold))
              .foregroundStyle(.white)
              .frame(width: 40, height: 40)
              .background(Circle().fill(.black.opacity(0.55)))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
          #if targetEnvironment(macCatalyst)
          .help("关闭（Esc）")
          #endif
        }
        .padding(.horizontal, 16)
        .opacity(dragProgress == 0 ? 1 : 0)
        }
        ZStack {
          if let player = playback.player {
            // 系统播放器：自带全屏、画中画、隔空播放、静音、进度。
            InlineVideoPlayer(player: player, onDrag: { dragProgress = $0 }, onDismiss: close, playback: playback.videoPlayback)
              #if targetEnvironment(macCatalyst)
              .overlay(alignment: .bottomTrailing) {
                MacVideoControlsButton(player: player, controllerProvider: { playback.videoPlayback.fullScreenController(for: $0) })
                  .frame(width: 40, height: 40).padding(16)
              }
              #endif
          } else if let videoMessage {
            Text(videoMessage).foregroundStyle(.white).multilineTextAlignment(.center).padding()
          } else {
            VStack(spacing: 10) {
              ProgressView().tint(.white)
              if fetching {
                Text(target.forward != nil ? "视频正在下载，下好后自动播放…" : "正在从 QQ 下载…").font(.footnote).foregroundStyle(.white.opacity(0.8))
              }
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .scaleEffect(visible ? 1 : 0.92)
      .opacity(visible ? 1 : 0)
    }
    .onAppear { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { visible = true } }
    .task { await playback.load { await videoURL() } }
    .onDisappear { playback.close() }
    #if targetEnvironment(macCatalyst)
    .background(MacMediaKeyboard(close: close))
    .onAppear { mediaWindow?.registerCleanup("video", action: playback.close) }
    #endif
  }

  private func close() {
    playback.close()
    #if targetEnvironment(macCatalyst)
    if let mediaWindow { mediaWindow.close(); return }
    #endif
    withAnimation(.easeIn(duration: 0.18)) { visible = false } completion: {
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) { dismiss() }
    }
  }

  private var showsCloseButton: Bool {
    #if targetEnvironment(macCatalyst)
    mediaWindow == nil
    #else
    true
    #endif
  }

  /// 已经在服务端的直接放；按需的、以前失败或过期的先让服务端当场从 QQ 下载（大视频要等一会儿）。
  private func videoURL() async -> URL? {
    var media = target.media
    if media.state != .stored && media.state != .purged, let f = target.forward {
      // 聊天记录里的视频：等待服务端的 mediaReady 推送，再取最新状态。
      fetching = true
      defer { fetching = false }
      guard let ready = await waitForwardMedia(f, ord: media.ord) else {
        videoMessage = "视频下载失败，QQ 上可能已经过期了"
        return nil
      }
      media = ready
    } else if media.state != .stored && media.state != .purged {
      guard target.seq > 0 else {
        videoMessage = "视频还没下载好"
        return nil
      }
      fetching = true
      var ref = Qqbridge_V1_MediaRef()
      ref.chatID = target.chatId
      ref.seq = target.seq
      ref.ord = media.ord
      var req = Qqbridge_V1_RequestMediaRequest()
      req.refs = [ref]
      req.original = true
      // 服务端还在下载就等它推「下好了」（先登记再请求）；没等到（断线、超时）再问一次。只有过期、失败才提示拿不到。
      let watch = MediaReady.shared.watch(chatId: target.chatId, seq: target.seq, ord: media.ord, thumb: false)
      var got: Qqbridge_V1_MediaInfo?
      for _ in 0..<6 {
        if Task.isCancelled { return nil }
        if let m = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get().media.first {
          if m.state == .stored, !m.sha256.isEmpty {
            got = m
            break
          }
          if m.state == .expired || m.state == .failed || m.state == .skipped { break }
        }
        if let e = await watch.next(timeout: .seconds(300)), e.state != "stored" { break }
      }
      fetching = false
      guard let got else {
        videoMessage = "视频已过期，QQ 上也拿不到了"
        return nil
      }
      media = got
    }
    let sha = media.playableSha256.isEmpty ? media.sha256 : media.playableSha256
    if media.state == .purged {
      // 原件已清理：先让服务端从 QQ 取回（取回前播放器拿不到内容），拿不到就提示。
      guard (try? await session.media.file(for: sha, chatId: chatId)) != nil else {
        videoMessage = "视频已过期，QQ 上也拿不到了"
        return nil
      }
    }
    if let url = try? await session.media.streamURL(for: sha) {
      return url
    } else {
      videoMessage = "视频打不开"
      return nil
    }
  }

  /// 聊天记录里某个节点的媒体下好了没有：下好了返回它，失败或等太久返回 nil。
  private func waitForwardMedia(_ f: ForwardRef, ord: UInt32) async -> Qqbridge_V1_MediaInfo? {
    var req = Qqbridge_V1_GetForwardRequest()
    req.chatID = target.chatId
    req.seq = f.seq
    req.path = f.path
    // 先登记，再看现在的状态；还在下载就等服务端推「下好了」，再取一次最新的媒体信息。
    let watch = MediaReady.shared.watchForward(chatId: target.chatId, seq: f.seq, path: f.path, node: f.node, ord: ord)
    for _ in 0..<6 {
      if Task.isCancelled { return nil }
      if let res = try? await session.api.messages.getForward(request: req, headers: session.api.headers).get(), f.node < res.nodes.count {
        for seg in res.nodes[f.node].segments {
          guard case .video(let v) = seg.kind, v.media.ord == ord else { continue }
          switch v.media.state {
          case .stored, .purged: return v.media
          case .failed, .expired: return nil
          default: break
          }
        }
      }
      _ = await watch.next(timeout: .seconds(300))
    }
    return nil
  }

  private var videoAspect: CGSize? {
    let m = target.media
    return m.width > 0 && m.height > 0 ? CGSize(width: Int(m.width), height: Int(m.height)) : CGSize(width: 16, height: 9)
  }
}

// MARK: - 合并转发

struct ForwardView: View {
  let session: Session
  let chatId: Int64
  let seq: Int64
  let path: [Int32]
  @Environment(\.dismiss) private var dismiss
  @State private var nodes: [Qqbridge_V1_ForwardNode] = []
  @State private var unavailable = false
  @State private var loading = true

  static func downloading(_ node: Qqbridge_V1_ForwardNode) -> Bool {
    node.segments.contains { seg in
      switch seg.kind {
      case .image(let i): i.media.state == .pending
      case .video(let v): v.media.state == .pending
      case .marketFace(let f): f.media.state == .pending
      default: false
      }
    }
  }

  var body: some View {
    List {
      ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(node.senderName).font(.caption.bold())
            Spacer()
            Text(Format.chatTime(node.time)).font(.caption2).foregroundStyle(.secondary)
          }
          ForEach(Array(node.segments.enumerated()), id: \.offset) { _, seg in
            ForwardSegmentView(segment: seg, session: session, chatId: chatId, seq: seq, path: path + [Int32(index)])
          }
        }
        .padding(.vertical, 2)
      }
    }
    .listStyle(.plain)
    .navigationTitle("聊天记录")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if path.isEmpty { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
    .overlay {
      if loading { ProgressView() } else if unavailable { ContentUnavailableView("聊天记录已无法查看", systemImage: "clock.badge.xmark") }
    }
    .task {
      var req = Qqbridge_V1_GetForwardRequest()
      req.chatID = chatId
      req.seq = seq
      req.path = path
      // 里面的图片 / 表情 / 视频还在下载：等服务端推「这一层有媒体下好了」再重新拉一次，下好就显示。
      let watch = MediaReady.shared.watchForward(chatId: chatId, seq: seq, path: path)
      for round in 0..<200 {
        if Task.isCancelled { return }
        if let res = try? await session.api.messages.getForward(request: req, headers: session.api.headers).get() {
          nodes = res.nodes
          unavailable = res.unavailable
        } else if round == 0 {
          unavailable = true
        }
        loading = false
        guard nodes.contains(where: Self.downloading) else { break }
        // 一批里常常几张一起下好：等到一个后再稍等一下，合并成一次刷新。
        guard await watch.next() != nil else { continue }
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
  }
}

struct ForwardSegmentView: View {
  let segment: Qqbridge_V1_Segment
  let session: Session
  let chatId: Int64
  let seq: Int64
  let path: [Int32]
  @State private var media: MediaTarget?
  @State private var unsupported: UnsupportedItem?
  @State private var profile: ProfileTarget?
  @State private var copied = false

  var body: some View {
    content
      .sheet(item: $unsupported) { UnsupportedDetailView(item: $0) }
      .profileCard(item: $profile) { target in
        NavigationStack {
          UserProfileView(session: session, userId: target.userId, groupMember: nil, asCard: true, onClose: { profile = nil })
        }
      }
  }

  @ViewBuilder private var content: some View {
    switch segment.kind {
    case .text(let t): Text(t.text).textSelection(.enabled)
    case .mention(let m): Text("@\(m.name.isEmpty ? String(m.userID) : m.name)").bold()
    case .face(let f): QQFace.inline(f.faceID, name: f.name)
    case .image(let i) where i.sticker:
      // 表情：和聊天里一样，原图、会动、不加底。
      CachedImage(sha256: i.media.state == .stored ? i.media.sha256 : (i.media.thumbSha256.isEmpty ? nil : i.media.thumbSha256), chatId: chatId, maxPixel: 420, animated: true) {
        Text(i.summary.isEmpty ? "[表情]" : i.summary).font(.caption).foregroundStyle(.secondary)
      }
      .aspectRatio(contentMode: .fit)
      .frame(maxWidth: 140, maxHeight: 140)
    case .image(let i):
      MediaThumb(media: i.media, width: i.width, height: i.height, chatId: chatId)
        .modifier(MessageBlockAction(title: "打开图片") { media = MediaTarget(kind: .image, media: i.media) })
        .mediaViewer(item: $media, session: session, chatId: chatId)
    case .video(let v):
      MediaThumb(media: v.media, width: v.width, height: v.height, chatId: chatId)
        .overlay {
          if v.media.state == .pending || v.media.state == .onDemand {
            // 服务端还在下载：转圈 + 大小，点开会等下好再播。
            VStack(spacing: 6) {
              ProgressView().tint(.white)
              Text(v.media.size > 0 ? "下载中 · \(Bytes.text(Int64(v.media.size)))" : "下载中").font(.caption2).foregroundStyle(.white)
            }
            .padding(10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
          } else if v.media.state == .failed || v.media.state == .expired {
            Label("视频已过期", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.white)
              .padding(8).background(.black.opacity(0.45), in: Capsule())
          } else {
            Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
          }
        }
        .modifier(MessageBlockAction(title: "播放视频", value: v.durationSec > 0 ? Format.duration(Int(v.durationSec)) : "") {
          let node = Int(path.last ?? 0)
          media = MediaTarget(kind: .video, media: v.media, chatId: chatId, forward: ForwardRef(seq: seq, path: Array(path.dropLast()), node: node))
        })
        .mediaViewer(item: $media, session: session, chatId: chatId)
    case .forward(let f):
      NavigationLink { ForwardView(session: session, chatId: chatId, seq: seq, path: path) } label: {
        Label(f.title.isEmpty ? "聊天记录" : f.title, systemImage: "text.bubble")
      }
    case .file(let f): Label(f.name, systemImage: "doc")
    case .record: Label("语音", systemImage: "waveform")
    case .marketFace(let f): Text(f.summary.isEmpty ? "[表情]" : f.summary)
    case .reply:
      // 引用的是原会话里的消息，聊天记录里拿不到原文：只标一下是回复。
      Label("回复了一条消息", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.secondary)
    case .lightApp(let a):
      if let card = ContactCard.parse(json: a.json, app: a.appName) {
        ContactCardView(card: card) { card in
          switch card.kind {
          case .user: profile = ProfileTarget(userId: card.uin)
          case .group:
            UIPasteboard.general.string = String(card.uin)
            copied = true
          }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if copied { Text("已复制群号").font(.caption2).padding(6).task { try? await Task.sleep(for: .seconds(1.5)); copied = false } }
        }
      } else if let card = AppCard.parse(json: a.json, app: a.appName) {
        AppCardView(card: card, outgoing: false)
          .padding(10)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      } else {
        Label(CardText.from(json: a.json, app: a.appName), systemImage: "rectangle.on.rectangle").font(.subheadline)
      }
    case .xml: Label("[卡片消息]", systemImage: "rectangle.on.rectangle").font(.subheadline)
    case .markdown(let m): MarkdownBlock(content: m.content, outgoing: false)
    case .mentionAll: Text("@全体成员").bold()
    case .unknown(let u):
      switch u.original {
      case "keyboard": EmptyView()
      case "dice": Text("[骰子]")
      case "rps": Text("[猜拳]")
      default: UnsupportedCard(item: UnsupportedItem(u)) { unsupported = $0 }
      }
    case .none: EmptyView()
    }
  }
}

// MARK: - 表情面板（我在 QQ 收藏的表情）

struct StickerPanel: View {
  /// Mac 的弹出框比手机屏幕宽、鼠标点得准：一行 6 个。
  #if targetEnvironment(macCatalyst)
  static let stickerColumns = 6
  #else
  static let stickerColumns = 4
  #endif
  let session: Session
  let onPick: (Qqbridge_V1_Sticker) -> Void
  /// 点了 QQ 小黄脸（插进输入框）；nil 时不显示小黄脸页。
  var onFace: ((Int, String) -> Void)? = nil
  /// 上次停在哪一页（QQ 表情 / 我的表情）。
  @AppStorage("stickerPanelTab") private var tab = 0
  @State private var stickers: [Qqbridge_V1_Sticker] = []
  @State private var prepared: [String: Qqbridge_V1_Sticker] = [:]
  @State private var requested: Set<String> = []
  @State private var error: String?
  /// "我的表情"上次看到的位置（最上面那个表情的 md5），下次打开接着看。
  @AppStorage("stickerPanelTop") private var savedTop = ""
  @State private var top: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        if tab == 0, let onFace {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 10) {
            ForEach(QQFace.pickable, id: \.id) { face in
              Button { onFace(face.id, face.name) } label: {
                QQFace.view(String(face.id), size: 32).frame(maxWidth: .infinity)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(face.name)
            }
          }
          .padding()
        } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.stickerColumns), spacing: 8) {
          ForEach(stickers, id: \.md5) { s in
            let ready = prepared[s.md5] ?? (s.sha256.isEmpty ? nil : s)
            Button {
              if let ready { onPick(ready) }
            } label: {
              // 方格里按原比例缩放放下，不拉伸。
              Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                  CachedImage(sha256: ready.map { $0.thumbSha256.isEmpty ? $0.sha256 : $0.thumbSha256 }, maxPixel: 240) {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                  }
                  .aspectRatio(contentMode: .fit)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onAppear { prepare(s) }
          }
        }
        .scrollTargetLayout()
        .padding()
        }
      }
      .scrollPosition(id: $top, anchor: .top)
      .onChange(of: top) { _, id in if let id, tab == 1 || onFace == nil { savedTop = id } }
      .onChange(of: tab) { _, t in
        // 切回"我的表情"：接着上次的位置。
        if t == 1, !savedTop.isEmpty { Task { try? await Task.sleep(for: .milliseconds(50)); top = savedTop } }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if onFace != nil {
          ToolbarItem(placement: .principal) {
            Picker("表情", selection: $tab) {
              Text("QQ 表情").tag(0)
              Text("我的表情 \(stickers.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
          }
        }
      }
      .navigationTitle(onFace == nil ? "我的表情 \(stickers.count)" : "")
      .overlay {
        if tab == 1 || onFace == nil {
          if let error { ContentUnavailableView("表情加载失败", systemImage: "face.dashed", description: Text(error)) } else if stickers.isEmpty { ProgressView() }
        }
      }
      .platformRefreshable { await load(refresh: true) }
      .task { await load(refresh: false) }
    }
  }

  private func load(refresh: Bool) async {
    var req = Qqbridge_V1_ListStickersRequest()
    req.refresh = refresh
    do {
      stickers = try await session.api.media.listStickers(request: req, headers: session.api.headers).get().stickers
      error = nil
      // 回到上次看到的位置（表情还在的话）。
      if top == nil, !savedTop.isEmpty, stickers.contains(where: { $0.md5 == savedTop }) {
        try? await Task.sleep(for: .milliseconds(50))
        top = savedTop
      }
    } catch {
      self.error = "\(error)"
    }
  }

  /// 滚动到哪准备到哪：攒一小批再请求。
  private func prepare(_ s: Qqbridge_V1_Sticker) {
    guard s.sha256.isEmpty, prepared[s.md5] == nil, !requested.contains(s.md5) else { return }
    requested.insert(s.md5)
    let batch = stickers.filter { $0.sha256.isEmpty && prepared[$0.md5] == nil }.map(\.md5)
      .drop { $0 != s.md5 }.prefix(24)
    for m in batch { requested.insert(m) }
    Task {
      var req = Qqbridge_V1_PrepareStickersRequest()
      req.md5 = Array(batch)
      if let res = try? await session.api.media.prepareStickers(request: req, headers: session.api.headers).get() {
        for p in res.stickers { prepared[p.md5] = p }
      }
      // 没准备好的（下载失败、超时）：允许下次显示到时再要。
      for m in batch where prepared[m] == nil { requested.remove(m) }
    }
  }
}

extension Qqbridge_V1_SharedMedia {
  var key: String { "\(seq):\(segment.hashValue)" }
}
