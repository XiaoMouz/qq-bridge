// 存储页的细看：本机缓存 / 服务器存储都按类型（图片、表情、视频、文件、语音、消息、其他）分，
// 点一类 → 各会话的占比；点一个会话 → 里面的具体内容（缩略图预览、点开查看），和别的会话共用的内容标出共用的会话数。
import QQBridgeKit
import QQBridgeProto
import QuickLook
import SwiftUI

/// 存储页的类型（服务器的细类合并成用户看得懂的几大类）。
enum StorageGroup: String, CaseIterable, Identifiable {
  case image, sticker, video, file, audio, message, other
  var id: String { rawValue }

  var name: String {
    switch self {
    case .image: "图片"
    case .sticker: "表情"
    case .video: "视频"
    case .file: "文件"
    case .audio: "语音"
    case .message: "消息"
    case .other: "其他"
    }
  }

  var icon: String {
    switch self {
    case .image: "photo"
    case .sticker: "face.smiling"
    case .video: "film"
    case .file: "doc"
    case .audio: "waveform"
    case .message: "text.bubble"
    case .other: "square.stack.3d.up"
    }
  }

  var color: Color {
    switch self {
    case .image: .blue
    case .sticker: .pink
    case .video: .purple
    case .file: .teal
    case .audio: .orange
    case .message: .green
    case .other: .gray
    }
  }

  /// 服务器的细类。
  var serverCategories: [String] {
    switch self {
    case .image: ["image", "qq_thumb"]
    case .sticker: ["sticker"]
    case .video: ["video"]
    case .file: ["file", "group_file"]
    case .audio: ["record"]
    case .message: ["message"]
    case .other: []
    }
  }

  /// 服务器的细类属于哪一大类（头像、旧版生成的缩略图和转码都算其他）。
  static func of(server category: String) -> StorageGroup {
    allCases.first { $0.serverCategories.contains(category) } ?? .other
  }

  var localKinds: [LocalStorageKind] {
    switch self {
    case .image: [.image]
    case .sticker: [.sticker]
    case .video: [.video]
    case .file: [.file]
    case .audio: [.audio]
    case .message: []
    case .other: [.other]
    }
  }

  static func of(local kind: LocalStorageKind) -> StorageGroup {
    switch kind {
    case .image: .image
    case .sticker: .sticker
    case .video: .video
    case .file: .file
    case .audio: .audio
    case .other: .other
    }
  }
}

/// 一类的汇总（列表的一行、环形图的一块）。
struct StorageGroupStat: Identifiable {
  let group: StorageGroup
  let bytes: Int64
  let count: Int
  var id: String { group.id }
}

/// 一行：色块、名字、大小、份数和占比。
struct StorageGroupRow: View {
  let stat: StorageGroupStat
  let total: Int64

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: stat.group.icon)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(stat.group.color.gradient, in: RoundedRectangle(cornerRadius: 7))
      Text(stat.group.name)
      Spacer()
      VStack(alignment: .trailing, spacing: 0) {
        Text(Bytes.text(stat.bytes)).monospacedDigit()
        Text("\(stat.count) \(stat.group == .message ? "条" : "份") · \(StorageMath.percent(stat.bytes, of: total))")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

enum StorageMath {
  static func percent(_ part: Int64, of total: Int64) -> String {
    guard total > 0 else { return "0%" }
    let p = Double(part) / Double(total) * 100
    return p < 1 ? "<1%" : "\(Int(p.rounded()))%"
  }
}

// MARK: - 一类在各会话的占比

/// 某类（本机或服务器）在各会话的占用，从大到小；点进去看会话里的具体内容。
struct StorageChatsView: View {
  enum Source { case local, server }
  let session: Session
  let source: Source
  let group: StorageGroup
  /// 所有媒体类型合起来（"占用最多的会话"）。
  var allMedia = false
  @State private var chats: [(chatId: Int64, bytes: Int64, count: Int, scene: Qqbridge_V1_Scene, peerId: Int64)] = []
  @State private var titles = ChatTitles()
  @State private var loading = true
  @State private var error: String?
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      let total = chats.reduce(Int64(0)) { $0 + $1.bytes }
      let maxBytes = max(chats.first?.bytes ?? 1, 1)
      if !chats.isEmpty {
        Section {
          LabeledContent("合计", value: Bytes.text(total))
          if source == .server, group == .message {
            Text("消息按每条在数据库里的大小算（文字、消息段和原始数据），数据量大时第一次统计要几秒。").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section(chats.isEmpty ? "" : "\(chats.count) 个会话") {
        ForEach(chats, id: \.chatId) { c in
          let title = titles.title(c.chatId, scene: c.scene, peerId: c.peerId, session: session)
          let row = VStack(alignment: .leading, spacing: 6) {
            HStack {
              AvatarView(sha256: titles.avatar(c.chatId, session: session), title: title, seed: c.peerId, size: 28)
              Text(c.chatId == 0 ? "不属于会话（头像等）" : title).lineLimit(1)
              Spacer()
              VStack(alignment: .trailing, spacing: 0) {
                Text(Bytes.text(c.bytes)).monospacedDigit()
                Text("\(c.count) \(group == .message ? "条" : "份") · \(StorageMath.percent(c.bytes, of: total))").font(.caption).foregroundStyle(.secondary)
              }
            }
            GeometryReader { geo in
              Capsule().fill(group.color.gradient)
                .frame(width: max(4, geo.size.width * CGFloat(Double(c.bytes) / Double(maxBytes))))
            }
            .frame(height: 5)
          }
          if group == .message {
            // 消息没有"具体内容"可列：点一下打开会话。
            Button { model.pendingChat = c.chatId } label: { row }.tint(.primary)
          } else {
            NavigationLink {
              if allMedia {
                ChatStorageView(session: session, chatId: c.chatId, title: title)
              } else {
                StorageItemsView(session: session, source: source, group: group, chatId: c.chatId, title: title)
              }
            } label: { row }
          }
        }
      }
    }
    .navigationTitle(allMedia ? "占用最多的会话" : group.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if group != .message, !allMedia {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink("全部") { StorageItemsView(session: session, source: source, group: group, chatId: nil, title: "全部\(group.name)") }
        }
      }
    }
    .overlay {
      if loading && chats.isEmpty { ProgressView() }
      else if let error { ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error)) }
      else if chats.isEmpty { ContentUnavailableView("没有\(group.name)", systemImage: group.icon) }
    }
    .task { await load() }
    .refreshable { await load() }
  }

  private func load() async {
    defer { loading = false }
    switch source {
    case .local:
      let list = group == .message
        ? ((try? session.store.messageUsage().byChat) ?? [])
        : ((try? session.store.cacheChats(kinds: group.localKinds)) ?? [])
      chats = list.map { (chatId: $0.chatId, bytes: $0.bytes, count: $0.count, scene: .unspecified, peerId: 0) }
    case .server:
      var req = Qqbridge_V1_ListStorageChatsRequest()
      req.categories = allMedia ? StorageGroup.allCases.filter { $0 != .message }.flatMap(\.serverCategories) : group.serverCategories
      req.limit = 200
      do {
        let res = try await session.api.media.listStorageChats(request: req, headers: session.api.headers).get()
        chats = res.chats.map { (chatId: $0.chatID, bytes: Int64($0.bytes), count: Int($0.count), scene: $0.scene, peerId: $0.peerID) }
        error = nil
      } catch {
        self.error = LoadState.describe(error)
      }
    }
  }
}

// MARK: - 会话里的具体内容

struct StorageItemsView: View {
  let session: Session
  let source: StorageChatsView.Source
  let group: StorageGroup
  /// nil = 全部会话。
  let chatId: Int64?
  let title: String
  @State private var items: [StorageItemModel] = []
  @State private var more = false
  @State private var loading = true
  @State private var preview: MediaTarget?
  @State private var fileURL: URL?
  @State private var sharing: StorageItemModel?
  @State private var error: String?

  private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

  var body: some View {
    ScrollView {
      if !items.isEmpty {
        let purged = items.filter(\.purged).count
        let stored = items.reduce(Int64(0)) { $0 + ($1.purged ? 0 : $1.size) }
        Text("\(items.count)\(more ? "+" : "") 份 · \(Bytes.text(stored))\(purged > 0 ? " · \(purged) 份原件已清理" : "")")
          .font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
      }
      LazyVGrid(columns: columns, spacing: 6) {
        ForEach(items) { item in
          StorageItemCell(item: item, onShared: { sharing = item })
            .onTapGesture { Task { await open(item) } }
            .onAppear { if item.id == items.last?.id, more { Task { await loadMore() } } }
        }
      }
      .padding(.horizontal, 6)
      if more { ProgressView().padding() }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if loading && items.isEmpty { ProgressView() }
      else if let error { ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error)) }
      else if items.isEmpty { ContentUnavailableView("没有\(group.name)", systemImage: group.icon) }
    }
    .mediaViewer(item: $preview, session: session, chatId: chatId ?? 0)
    .quickLookPreview($fileURL)
    .sheet(item: $sharing) { item in
      SharedChatsSheet(session: session, source: source, item: item)
        .presentationDetents([.medium, .large])
    }
    .task { await loadMore() }
  }

  private func loadMore() async {
    defer { loading = false }
    switch source {
    case .local:
      let list = (try? session.store.cacheItems(chatId: chatId, kinds: group.localKinds)) ?? []
      items = list.map(StorageItemModel.init(local:))
      more = false
    case .server:
      var req = Qqbridge_V1_ListStorageItemsRequest()
      req.chatID = chatId ?? 0
      req.categories = group.serverCategories
      req.offset = UInt32(items.count)
      req.limit = 60
      do {
        let res = try await session.api.media.listStorageItems(request: req, headers: session.api.headers).get()
        items += res.items.map(StorageItemModel.init(server:))
        more = res.more
        error = nil
      } catch {
        self.error = LoadState.describe(error)
        more = false
      }
    }
  }

  /// 图片、表情、视频在查看器里打开；文件、语音下载后用 QuickLook 打开。
  private func open(_ item: StorageItemModel) async {
    var media = Qqbridge_V1_MediaInfo()
    media.sha256 = item.sha256
    media.thumbSha256 = item.thumbSha256 ?? ""
    media.state = item.purged ? .purged : .stored
    switch item.group {
    case .image, .sticker:
      preview = MediaTarget(kind: .image, media: media, chatId: item.chatId, seq: item.seq)
    case .video:
      preview = MediaTarget(kind: .video, media: media, chatId: item.chatId, seq: item.seq)
    default:
      guard let file = try? await session.media.file(for: item.sha256, chatId: item.chatId) else {
        error = "文件打不开：QQ 上已经拿不到了"
        return
      }
      let named = FileManager.default.temporaryDirectory.appendingPathComponent(item.name ?? "\(item.sha256.prefix(12)).\(item.fileExtension)")
      try? FileManager.default.removeItem(at: named)
      try? FileManager.default.copyItem(at: file, to: named)
      fileURL = named
    }
  }
}

/// 一份内容（本机或服务器的统一表示）。
struct StorageItemModel: Identifiable {
  let sha256: String
  let size: Int64
  let group: StorageGroup
  let chatId: Int64
  let seq: Int64
  let refChats: Int
  let thumbSha256: String?
  let name: String?
  let mime: String?
  let purged: Bool
  let cold: Bool
  var id: String { sha256 }

  init(local: LocalStorageItem) {
    sha256 = local.sha256
    size = local.size
    group = StorageGroup.of(local: local.kind)
    chatId = local.chatId
    seq = local.seq
    refChats = local.refChats
    thumbSha256 = nil
    name = nil
    mime = nil
    purged = false
    cold = false
  }

  init(server: Qqbridge_V1_StorageItem) {
    sha256 = server.sha256
    size = Int64(server.size)
    group = StorageGroup.of(server: server.category)
    chatId = server.chatID
    seq = server.seq
    refChats = Int(server.refChats)
    thumbSha256 = server.thumbSha256.isEmpty ? nil : server.thumbSha256
    name = server.name.isEmpty ? nil : server.name
    mime = server.mime.isEmpty ? nil : server.mime
    purged = server.state == "purged"
    cold = server.tier == "cold"
  }

  /// 预览图：缩略图优先；图片、表情没有缩略图时用它自己。
  var previewSha256: String? {
    if let thumbSha256 { return thumbSha256 }
    return group == .image || group == .sticker || group == .other ? sha256 : nil
  }

  var fileExtension: String {
    switch mime {
    case "application/pdf": "pdf"
    case "audio/mp4", "audio/aac": "m4a"
    case "audio/mpeg": "mp3"
    case "video/mp4": "mp4"
    default: group == .audio ? "m4a" : "bin"
    }
  }
}

/// 网格里的一格：预览、类型角标、大小、共用的会话数。
struct StorageItemCell: View {
  let item: StorageItemModel
  let onShared: () -> Void

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if let sha = item.previewSha256 {
          CachedImage(sha256: sha, chatId: item.chatId, maxPixel: 300) { placeholder }
            .aspectRatio(contentMode: item.group == .sticker ? .fit : .fill)
        } else {
          placeholder
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(alignment: .bottomLeading) {
        HStack(spacing: 3) {
          if item.group == .video { Image(systemName: "play.fill") }
          if item.cold { Image(systemName: "snowflake") }
          if item.purged { Image(systemName: "icloud.slash") }
          Text(Bytes.text(item.size))
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(5)
      }
      .overlay(alignment: .topTrailing) {
        // 和别的会话共用：链接图标 + 会话数，点一下看是哪些会话。
        if item.refChats > 1 {
          Button(action: onShared) {
            Label("\(item.refChats)", systemImage: "link")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6).padding(.vertical, 3)
              .background(Color.accentColor, in: Capsule())
          }
          .buttonStyle(.plain)
          .padding(5)
          .accessibilityLabel("被 \(item.refChats) 个会话引用")
        }
      }
      .contentShape(Rectangle())
  }

  private var placeholder: some View {
    ZStack {
      Rectangle().fill(item.group.color.opacity(0.15))
      VStack(spacing: 4) {
        Image(systemName: item.group.icon).font(.title2).foregroundStyle(item.group.color)
        if let name = item.name {
          Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 4)
        }
      }
    }
  }
}

/// 一份内容被哪些会话引用：本机按本地记录，服务器按服务端的出处（ListMediaUsages）。点一个打开会话。
struct SharedChatsSheet: View {
  let session: Session
  let source: StorageChatsView.Source
  let item: StorageItemModel
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var chats: [(chatId: Int64, seq: Int64, scene: Qqbridge_V1_Scene, peerId: Int64)] = []
  @State private var titles = ChatTitles()

  var body: some View {
    NavigationStack {
      List(chats, id: \.chatId) { c in
        let title = titles.title(c.chatId, scene: c.scene, peerId: c.peerId, session: session)
        Button {
          dismiss()
          model.pendingChat = c.chatId
        } label: {
          HStack(spacing: 12) {
            AvatarView(sha256: titles.avatar(c.chatId, session: session), title: title, seed: c.peerId, size: 34)
            Text(title).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
        }
        .tint(.primary)
      }
      .navigationTitle("被 \(item.refChats) 个会话引用")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
    }
    .task {
      switch source {
      case .local:
        chats = ((try? session.store.chatsReferencing(item.sha256)) ?? []).map { ($0.chatId, $0.seq, .unspecified, 0) }
      case .server:
        var req = Qqbridge_V1_ListMediaUsagesRequest()
        req.sha256 = item.sha256
        let usages = (try? await session.api.media.listMediaUsages(request: req, headers: session.api.headers).get().usages) ?? []
        var seen: Set<Int64> = []
        chats = usages.compactMap { u in seen.insert(u.chatID).inserted ? (u.chatID, u.messageSeq, u.scene, u.peerID) : nil }
      }
    }
  }
}

/// 会话名和头像（从本地会话列表查，查不到用号码）。
@MainActor
final class ChatTitles {
  private var dialogs: [Int64: DialogItem]?

  private func load(_ session: Session) -> [Int64: DialogItem] {
    if let dialogs { return dialogs }
    let list = (try? session.store.dialogItems(limit: 5000)) ?? []
    let map = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    dialogs = map
    return map
  }

  func title(_ chatId: Int64, scene: Qqbridge_V1_Scene, peerId: Int64, session: Session) -> String {
    if let d = load(session)[chatId] { return d.title }
    if peerId == 0 { return "会话 \(chatId)" }
    return scene == .group ? "群 \(String(peerId))" : "QQ \(String(peerId))"
  }

  func avatar(_ chatId: Int64, session: Session) -> String? {
    load(session)[chatId]?.peer.flatMap { $0.avatarSha256.isEmpty ? nil : $0.avatarSha256 }
  }
}
