// 大图 / 视频查看、合并转发、表情面板、会话内搜索、共享媒体。
import AVKit
import QQBridgeKit
import QQBridgeProto
import SwiftUI

// MARK: - 大图与视频

struct MediaViewer: View {
  let target: MediaTarget
  let session: Session
  let chatId: Int64
  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer?
  /// 放不了时的说明（过期、下载失败）。
  @State private var videoMessage: String?
  @State private var fetching = false

  var body: some View {
    if target.kind == .image {
      ImageViewer(target: target, session: session, chatId: chatId)
    } else {
      videoBody
    }
  }

  private var videoBody: some View {
    MediaPopover(aspect: videoAspect) {
      EmptyView()
    } content: {
      ZStack {
        Color.black
        if let player {
          InlineVideoPlayer(player: player)
        } else if let videoMessage {
          Text(videoMessage).foregroundStyle(.white).multilineTextAlignment(.center).padding()
        } else {
          VStack(spacing: 10) {
            ProgressView().tint(.white)
            if fetching { Text("正在从 QQ 下载…").font(.footnote).foregroundStyle(.white.opacity(0.8)) }
          }
        }
      }
    }
    .task { await loadVideo() }
    .onDisappear { VideoPlayback.shared.previewClosed(player) }
  }

  /// 已经在服务端的直接放；按需的、以前失败或过期的先让服务端当场从 QQ 下载（大视频要等一会儿）。
  private func loadVideo() async {
    var media = target.media
    if media.state != .stored && media.state != .purged {
      guard target.seq > 0 else {
        videoMessage = "视频还没下载好"
        return
      }
      fetching = true
      var ref = Qqbridge_V1_MediaRef()
      ref.chatID = target.chatId
      ref.seq = target.seq
      ref.ord = media.ord
      var req = Qqbridge_V1_RequestMediaRequest()
      req.refs = [ref]
      req.original = true
      let res = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get()
      fetching = false
      guard let got = res?.media.first, got.state == .stored, !got.sha256.isEmpty else {
        videoMessage = "视频已过期，QQ 上也拿不到了"
        return
      }
      media = got
    }
    let sha = media.playableSha256.isEmpty ? media.sha256 : media.playableSha256
    if media.state == .purged {
      // 原件已清理：先让服务端从 QQ 取回（取回前播放器拿不到内容），拿不到就提示。
      guard (try? await session.media.file(for: sha, chatId: chatId)) != nil else {
        videoMessage = "视频已过期，QQ 上也拿不到了"
        return
      }
    }
    if let url = try? await session.media.streamURL(for: sha) {
      let p = AVPlayer(url: url)
      player = p
      p.play()
    } else {
      videoMessage = "视频打不开"
    }
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
      // 里面的图片 / 表情还在下载时每 2 秒再拉一次（最多 1 分钟），下好就显示。
      for round in 0..<30 {
        if let res = try? await session.api.messages.getForward(request: req, headers: session.api.headers).get() {
          nodes = res.nodes
          unavailable = res.unavailable
        } else if round == 0 {
          unavailable = true
        }
        loading = false
        guard nodes.contains(where: Self.downloading) else { break }
        try? await Task.sleep(for: .seconds(2))
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

  var body: some View {
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
        .onTapGesture { media = MediaTarget(kind: .image, media: i.media) }
        .mediaViewer(item: $media, session: session, chatId: chatId)
    case .video(let v):
      MediaThumb(media: v.media, width: v.width, height: v.height, chatId: chatId)
        .overlay { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white) }
        .onTapGesture { media = MediaTarget(kind: .video, media: v.media) }
        .mediaViewer(item: $media, session: session, chatId: chatId)
    case .forward(let f):
      NavigationLink { ForwardView(session: session, chatId: chatId, seq: seq, path: path) } label: {
        Label(f.title.isEmpty ? "聊天记录" : f.title, systemImage: "text.bubble")
      }
    case .file(let f): Label(f.name, systemImage: "doc")
    case .record: Label("语音", systemImage: "waveform")
    case .marketFace(let f): Text(f.summary.isEmpty ? "[表情]" : f.summary)
    default: Text("[暂不支持的内容]").foregroundStyle(.secondary)
    }
  }
}

// MARK: - 表情面板（我在 QQ 收藏的表情）

struct StickerPanel: View {
  let session: Session
  let onPick: (Qqbridge_V1_Sticker) -> Void
  /// 点了 QQ 小黄脸（插进输入框）；nil 时不显示小黄脸页。
  var onFace: ((Int, String) -> Void)? = nil
  @State private var tab = 0
  @State private var stickers: [Qqbridge_V1_Sticker] = []
  @State private var prepared: [String: Qqbridge_V1_Sticker] = [:]
  @State private var requested: Set<String> = []
  @State private var error: String?

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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
          ForEach(stickers, id: \.md5) { s in
            let ready = prepared[s.md5] ?? (s.sha256.isEmpty ? nil : s)
            Button {
              if let ready { onPick(ready) }
            } label: {
              CachedImage(sha256: ready.map { $0.thumbSha256.isEmpty ? $0.sha256 : $0.thumbSha256 }, maxPixel: 240) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
              }
              .aspectRatio(1, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onAppear { prepare(s) }
          }
        }
        .padding()
        }
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
      .refreshable { await load(refresh: true) }
      .task { await load(refresh: false) }
    }
  }

  private func load(refresh: Bool) async {
    var req = Qqbridge_V1_ListStickersRequest()
    req.refresh = refresh
    do {
      stickers = try await session.api.media.listStickers(request: req, headers: session.api.headers).get().stickers
      error = nil
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
    }
  }
}

// MARK: - 会话内搜索、共享媒体

struct ChatSearchView: View {
  let session: Session
  let chatId: Int64
  @State private var query = ""
  @State private var results: [Qqbridge_V1_Message] = []
  @State private var searching = false

  var body: some View {
    List(results, id: \.searchKey) { m in
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(senderName(m)).font(.caption.bold())
          Spacer()
          Text(Format.chatTime(m.time)).font(.caption2).foregroundStyle(.secondary)
        }
        Text(Format.preview(m)).font(.subheadline).lineLimit(4)
      }
    }
    .listStyle(.plain)
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索这个会话的聊天记录")
    .onSubmit(of: .search) { Task { await search() } }
    .navigationTitle("查找聊天记录")
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if searching { ProgressView() } else if results.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
    }
  }

  private func senderName(_ m: Qqbridge_V1_Message) -> String {
    guard let d = try? session.store.dialog(chatId: chatId) else { return String(m.senderID) }
    return (try? session.store.userName(qqAccountId: d.qqAccountID, userId: m.senderID)) ?? String(m.senderID)
  }

  private func search() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return }
    searching = true
    defer { searching = false }
    var req = Qqbridge_V1_SearchMessagesRequest()
    req.query = q
    req.chatID = chatId
    req.limit = 100
    results = (try? await session.api.messages.searchMessages(request: req, headers: session.api.headers).get().messages) ?? []
  }
}

struct SharedMediaView: View {
  let session: Session
  let chatId: Int64
  @State private var items: [Qqbridge_V1_SharedMedia] = []
  @State private var next: Int64 = 0
  @State private var done = false
  @State private var target: MediaTarget?

  var body: some View {
    ScrollView {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
        ForEach(items, id: \.key) { item in
          tile(item)
            .onAppear { if item.key == items.last?.key { Task { await load() } } }
        }
      }
    }
    .navigationTitle("图片与视频")
    .navigationBarTitleDisplayMode(.inline)
    .mediaViewer(item: $target, session: session, chatId: chatId)
    .task { await load() }
  }

  @ViewBuilder private func tile(_ item: Qqbridge_V1_SharedMedia) -> some View {
    let media: Qqbridge_V1_MediaInfo? = {
      switch item.segment.kind {
      case .image(let i): return i.media
      case .video(let v): return v.media
      default: return nil
      }
    }()
    if let media {
      CachedImage(sha256: media.thumbSha256, chatId: chatId) { Rectangle().fill(.quaternary) }
        .aspectRatio(1, contentMode: .fill)
        .frame(minHeight: 120)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
          if item.kind == .video { Image(systemName: "play.fill").foregroundStyle(.white).padding(6) }
        }
        .onTapGesture { target = MediaTarget(kind: item.kind == .video ? .video : .image, media: media, chatId: chatId, seq: item.seq) }
    }
  }

  private func load() async {
    guard !done else { return }
    var req = Qqbridge_V1_ListSharedMediaRequest()
    req.chatID = chatId
    req.kinds = [.image, .video]
    req.beforeSeq = next
    req.limit = 60
    guard let res = try? await session.api.messages.listSharedMedia(request: req, headers: session.api.headers).get() else { return }
    items += res.items
    next = res.nextBeforeSeq
    if next == 0 { done = true }
  }
}

extension Qqbridge_V1_SharedMedia {
  var key: String { "\(seq):\(segment.hashValue)" }
}
