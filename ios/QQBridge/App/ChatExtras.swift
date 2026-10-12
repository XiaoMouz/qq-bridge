// 会话详情里的子页面：查找聊天记录、图片视频与文件、群公告（含详情）、群相册（相册列表、相册里的照片）；
// 以及网络图片的看大图（群公告、群相册的图片是 QQ 的公开链接，不在服务端存档里）。
import AVKit
import QuickLook
import QQBridgeKit
import QQBridgeProto
import SwiftUI

// MARK: - 跳到聊天里的某条消息

/// 从会话详情里的子页面跳回聊天、定位到某条消息（看上下文）。
struct MessageJump: Equatable {
  let chatId: Int64
  let seq: Int64
  let id = UUID()
}

/// 聊天页接收跳转：是这个会话的就收起详情页，滚到那条消息并高亮。
struct MessageJumpHandler: ViewModifier {
  let chatId: Int64
  let onJump: (Int64) -> Void
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    content.onChange(of: model.messageJump, initial: true) { _, jump in
      guard let jump, jump.chatId == chatId else { return }
      model.messageJump = nil
      onJump(jump.seq)
    }
  }
}

// MARK: - 查找聊天记录

/// 在服务端的完整聊天记录里查找：按搜索键才查，点结果回到聊天里的那条消息。
struct ChatSearchView: View {
  let session: Session
  let chatId: Int64
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var results: [Qqbridge_V1_Message] = []
  @State private var searching = false
  /// 上一次真正查过的关键词（还没按搜索时不显示"未找到"）。
  @State private var searched: String?
  @State private var failed: String?

  var body: some View {
    List(results, id: \.searchKey) { m in
      Button { model.openMessage(chatId: chatId, seq: m.seq) } label: {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(senderName(m)).font(.caption.bold())
            Spacer()
            Text(Format.chatTime(m.time)).font(.caption2).foregroundStyle(.secondary)
          }
          Text(highlighted(Format.preview(m))).font(.subheadline).lineLimit(4)
        }
      }
      .tint(.primary)
    }
    .listStyle(.plain)
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索这个会话的聊天记录")
    .onSubmit(of: .search) { Task { await search() } }
    .onChange(of: query) { _, q in
      if q.trimmingCharacters(in: .whitespaces).isEmpty {
        results = []
        searched = nil
      }
    }
    .navigationTitle("查找聊天记录")
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if searching {
        ProgressView("正在服务器上查找…")
      } else if let failed {
        ContentUnavailableView("查找失败", systemImage: "exclamationmark.triangle", description: Text(failed))
      } else if let searched, results.isEmpty {
        ContentUnavailableView.search(text: searched)
      } else if searched == nil {
        ContentUnavailableView("输入关键词后按搜索", systemImage: "magnifyingglass", description: Text("在服务器上保存的全部聊天记录里查找，点结果回到聊天里的那条消息"))
      }
    }
  }

  private func highlighted(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    guard let key = searched, !key.isEmpty else { return out }
    var from = out.startIndex
    while let r = out[from...].range(of: key, options: .caseInsensitive) {
      out[r].foregroundColor = .accentColor
      out[r].font = .subheadline.bold()
      from = r.upperBound
    }
    return out
  }

  private func senderName(_ m: Qqbridge_V1_Message) -> String {
    guard let d = try? session.store.dialog(chatId: chatId) else { return String(m.senderID) }
    if m.senderID == (try? session.store.selfUin(qqAccountId: d.qqAccountID)) { return "我" }
    if !m.senderName.isEmpty { return m.senderName }
    return (try? session.store.userName(qqAccountId: d.qqAccountID, userId: m.senderID)) ?? String(m.senderID)
  }

  private func search() async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return }
    searching = true
    failed = nil
    defer { searching = false }
    var req = Qqbridge_V1_SearchMessagesRequest()
    req.query = q
    req.chatID = chatId
    req.limit = 200
    do {
      results = try await session.api.messages.searchMessages(request: req, headers: session.api.headers).get().messages
      searched = q
    } catch {
      results = []
      failed = LoadState.describe(error)
    }
  }
}

// MARK: - 图片、视频与文件

struct SharedMediaView: View {
  let session: Session
  let chatId: Int64
  @Environment(AppModel.self) private var model

  enum Tab: String, CaseIterable { case media = "图片与视频", files = "文件" }
  enum Sort: String, CaseIterable {
    case newest = "最新", oldest = "最早", largest = "最大", sender = "按发送者"
    var api: String {
      switch self {
      case .newest: "time_desc"
      case .oldest: "time_asc"
      case .largest: "size_desc"
      case .sender: "sender"
      }
    }
  }

  @State private var tab = Tab.media
  @State private var sort = Sort.newest
  @State private var items: [Qqbridge_V1_SharedMedia] = []
  @State private var nextBefore: Int64 = 0
  @State private var nextOffset: Int32 = 0
  @State private var done = false
  @State private var loading = false
  @State private var target: MediaTarget?
  @State private var fileURL: URL?
  @State private var opening: String?
  @State private var error: String?
  @State private var requester = MediaRequester()
  @State private var names: [Int64: String] = [:]

  var body: some View {
    Group {
      if tab == .media { mediaGrid } else { fileList }
    }
    .safeAreaInset(edge: .top) {
      Picker("类型", selection: $tab) {
        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.bar)
    }
    .navigationTitle("图片、视频与文件")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("排序", selection: $sort) {
            ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
        } label: {
          Label("排序", systemImage: "arrow.up.arrow.down")
        }
      }
    }
    .overlay {
      if items.isEmpty, loading {
        ProgressView()
      } else if items.isEmpty, done {
        ContentUnavailableView(tab == .media ? "没有图片和视频" : "没有文件", systemImage: tab == .media ? "photo.on.rectangle" : "doc")
      }
    }
    .mediaViewer(item: $target, session: session, chatId: chatId)
    .quickLookPreview($fileURL)
    .alert("打不开", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), presenting: error) { _ in
      Button("好") { error = nil }
    } message: { Text($0) }
    .task(id: "\(tab.rawValue)|\(sort.rawValue)") { await reload() }
  }

  // MARK: 列表

  /// 按排序分组：时间排序按月，发送者排序按人，大小排序不分组。
  private var sections: [(title: String, items: [Qqbridge_V1_SharedMedia])] {
    switch sort {
    case .largest:
      return [("", items)]
    case .sender:
      var out: [(String, [Qqbridge_V1_SharedMedia])] = []
      for item in items {
        let name = senderName(item.senderID)
        if out.last?.0 == name { out[out.count - 1].1.append(item) } else { out.append((name, [item])) }
      }
      return out
    case .newest, .oldest:
      var out: [(String, [Qqbridge_V1_SharedMedia])] = []
      for item in items {
        let month = Date(timeIntervalSince1970: TimeInterval(item.time)).formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN")))
        if out.last?.0 == month { out[out.count - 1].1.append(item) } else { out.append((month, [item])) }
      }
      return out
    }
  }

  private var mediaGrid: some View {
    ScrollView {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2, pinnedViews: [.sectionHeaders]) {
        ForEach(sections, id: \.title) { section in
          Section {
            ForEach(section.items, id: \.key) { item in
              SharedMediaTile(item: item, chatId: chatId, session: session, requester: requester, showSize: sort == .largest)
                .onTapGesture { open(item) }
                .contextMenu {
                  Button("在聊天中查看", systemImage: "text.bubble") { model.openMessage(chatId: chatId, seq: item.seq) }
                }
                .onAppear { if item.key == items.last?.key { Task { await loadMore() } } }
            }
          } header: {
            if !section.title.isEmpty {
              Text(section.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
          }
        }
      }
    }
  }

  private var fileList: some View {
    List {
      ForEach(sections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.items, id: \.key) { item in
            fileRow(item)
              .onAppear { if item.key == items.last?.key { Task { await loadMore() } } }
          }
        }
      }
    }
    .listStyle(.plain)
  }

  @ViewBuilder private func fileRow(_ item: Qqbridge_V1_SharedMedia) -> some View {
    if case .file(let f) = item.segment.kind {
      Button { Task { await openFile(f, seq: item.seq) } } label: {
        HStack(spacing: 12) {
          Image(systemName: FileIcon.symbol(f.name))
            .font(.title2)
            .foregroundStyle(FileIcon.color(f.name))
            .frame(width: 40, height: 40)
            .background(FileIcon.color(f.name).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
          VStack(alignment: .leading, spacing: 3) {
            Text(f.name).font(.subheadline).lineLimit(2)
            Text("\(Bytes.text(Int64(item.size > 0 ? item.size : f.media.size))) · \(senderName(item.senderID)) · \(Format.date(item.time))")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
          if opening == item.key { ProgressView() }
        }
      }
      .tint(.primary)
      .contextMenu {
        Button("在聊天中查看", systemImage: "text.bubble") { model.openMessage(chatId: chatId, seq: item.seq) }
      }
    }
  }

  // MARK: 打开

  private func open(_ item: Qqbridge_V1_SharedMedia) {
    let images = items.compactMap { i -> MediaTarget? in
      guard case .image(let img) = i.segment.kind else { return nil }
      return MediaTarget(kind: .image, media: img.media, chatId: chatId, seq: i.seq)
    }
    switch item.segment.kind {
    case .image(let i):
      var t = MediaTarget(kind: .image, media: i.media, chatId: chatId, seq: item.seq)
      t.gallery = images
      target = t
    case .video(let v):
      target = MediaTarget(kind: .video, media: v.media, chatId: chatId, seq: item.seq)
    default:
      break
    }
  }

  private func openFile(_ f: Qqbridge_V1_FileSegment, seq: Int64) async {
    let key = "\(seq):\(f.media.ord)"
    opening = key
    defer { opening = nil }
    var sha = f.media.state == .stored ? f.media.sha256 : ""
    if sha.isEmpty {
      // 原件还没下载：让服务端从 QQ 拉（大文件要等一会儿）。
      var ref = Qqbridge_V1_MediaRef()
      ref.chatID = chatId
      ref.seq = seq
      ref.ord = f.media.ord
      var req = Qqbridge_V1_RequestMediaRequest()
      req.refs = [ref]
      req.original = true
      for _ in 0..<60 {
        if let m = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get().media.first {
          if m.state == .stored, !m.sha256.isEmpty { sha = m.sha256; break }
          if m.state == .expired || m.state == .failed || m.state == .skipped { break }
        }
        try? await Task.sleep(for: .seconds(2))
      }
    }
    guard !sha.isEmpty, let cached = try? await session.media.file(for: sha, chatId: chatId) else {
      error = "文件已经过期，QQ 上也拿不到了"
      return
    }
    let named = FileManager.default.temporaryDirectory.appendingPathComponent(f.name.isEmpty ? cached.lastPathComponent : f.name)
    try? FileManager.default.removeItem(at: named)
    try? FileManager.default.copyItem(at: cached, to: named)
    fileURL = named
  }

  // MARK: 加载

  private func senderName(_ id: Int64) -> String {
    if let n = names[id] { return n }
    guard let d = try? session.store.dialog(chatId: chatId) else { return String(id) }
    let n: String
    if id == (try? session.store.selfUin(qqAccountId: d.qqAccountID)) { n = "我" } else {
      n = (try? session.store.userName(qqAccountId: d.qqAccountID, userId: id)) ?? String(id)
    }
    DispatchQueue.main.async { names[id] = n }
    return n
  }

  private func reload() async {
    items = []
    nextBefore = 0
    nextOffset = 0
    done = false
    await loadMore()
  }

  private func loadMore() async {
    guard !done, !loading else { return }
    loading = true
    defer { loading = false }
    var req = Qqbridge_V1_ListSharedMediaRequest()
    req.chatID = chatId
    req.kinds = tab == .media ? [.image, .video] : [.file]
    req.limit = 80
    req.sort = sort.api
    if sort == .newest { req.beforeSeq = nextBefore } else { req.offset = nextOffset }
    guard let res = try? await session.api.messages.listSharedMedia(request: req, headers: session.api.headers).get() else {
      done = true
      return
    }
    items += res.items
    if sort == .newest {
      nextBefore = res.nextBeforeSeq
      done = res.nextBeforeSeq == 0
    } else {
      nextOffset = res.nextOffset
      done = res.nextOffset == 0
    }
  }
}

/// 共享媒体的一格：有缩略图就显示；没有就向服务端要，下好后（隔一会儿拉一次这条消息）自动换上。
struct SharedMediaTile: View {
  let item: Qqbridge_V1_SharedMedia
  let chatId: Int64
  let session: Session
  let requester: MediaRequester
  var showSize = false
  @State private var fresh: Qqbridge_V1_MediaInfo?

  private var media: Qqbridge_V1_MediaInfo? {
    if let fresh { return fresh }
    switch item.segment.kind {
    case .image(let i): return i.media
    case .video(let v): return v.media
    default: return nil
    }
  }

  private var displaySha: String? {
    guard let m = media else { return nil }
    for sha in [m.thumbSha256, m.previewSha256, m.state == .stored && item.kind == .image ? m.sha256 : ""] where !sha.isEmpty { return sha }
    return nil
  }

  var body: some View {
    Color.clear
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        CachedImage(sha256: displaySha, chatId: chatId, maxPixel: 300) {
          ZStack {
            Rectangle().fill(.quaternary)
            if media?.state == .expired || media?.state == .failed {
              Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else if item.kind == .video {
              // 没有封面的视频：不为了封面去下整个视频。
              Image(systemName: "film").font(.title3).foregroundStyle(.secondary)
            } else {
              ProgressView().controlSize(.small)
            }
          }
        }
        .aspectRatio(contentMode: .fill)
      }
      .clipped()
      .overlay(alignment: .bottomLeading) {
        if item.kind == .video {
          Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if showSize, item.size > 0 {
          Text(Bytes.text(Int64(item.size))).font(.caption2.monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.5), in: Capsule()).padding(4)
        }
      }
      .contentShape(Rectangle())
      .task(id: item.key) { await fetchThumbIfNeeded() }
  }

  private func fetchThumbIfNeeded() async {
    guard item.kind == .image, displaySha == nil, let m = media, m.state != .expired, m.state != .failed else { return }
    requester.want(chatId: chatId, seq: item.seq, ord: m.ord, session: session)
    for _ in 0..<15 {
      try? await Task.sleep(for: .seconds(2))
      if Task.isCancelled { return }
      guard let msg = await session.sync.fetchMessage(chatId: chatId, seq: item.seq) else { continue }
      for seg in msg.segments {
        let info: Qqbridge_V1_MediaInfo? = switch seg.kind {
        case .image(let i): i.media
        case .video(let v): v.media
        default: nil
        }
        if let info, info.ord == m.ord, !info.thumbSha256.isEmpty || info.state == .stored {
          fresh = info
          return
        }
      }
    }
  }
}

enum FileIcon {
  static func symbol(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "pdf": "doc.richtext.fill"
    case "zip", "rar", "7z", "tar", "gz": "doc.zipper"
    case "doc", "docx", "pages", "txt", "md", "rtf": "doc.text.fill"
    case "xls", "xlsx", "csv", "numbers": "tablecells.fill"
    case "ppt", "pptx", "key": "rectangle.on.rectangle.angled.fill"
    case "mp3", "m4a", "wav", "flac", "aac": "music.note"
    case "mp4", "mov", "mkv", "avi": "film.fill"
    case "jpg", "jpeg", "png", "gif", "heic", "webp": "photo.fill"
    case "apk", "ipa", "exe", "dmg": "shippingbox.fill"
    default: "doc.fill"
    }
  }

  static func color(_ name: String) -> Color {
    switch (name as NSString).pathExtension.lowercased() {
    case "pdf": .red
    case "zip", "rar", "7z", "tar", "gz": .brown
    case "doc", "docx", "pages", "txt", "md", "rtf": .blue
    case "xls", "xlsx", "csv", "numbers": .green
    case "ppt", "pptx", "key": .orange
    case "mp3", "m4a", "wav", "flac", "aac": .pink
    case "mp4", "mov", "mkv", "avi": .purple
    default: .gray
    }
  }
}

// MARK: - 群公告

struct GroupNoticesView: View {
  let session: Session
  let groupId: Int64
  @State private var notices: [Qqbridge_V1_GroupNotice] = []
  @State private var state = LoadState.loading

  var body: some View {
    List(notices, id: \.id) { n in
      NavigationLink { NoticeDetailView(session: session, notice: n) } label: {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            if n.pinned { NoticeTag(text: "置顶", color: .orange) }
            Text(n.senderName).font(.subheadline.bold()).lineLimit(1)
            Spacer()
            Text(Format.date(n.time)).font(.caption).foregroundStyle(.secondary)
          }
          Text(n.text).font(.subheadline).lineLimit(3).foregroundStyle(.primary)
          if !n.imageUrls.isEmpty {
            HStack(spacing: 4) {
              ForEach(n.imageUrls.prefix(4), id: \.self) { url in
                RemoteImage(url: URL(string: url), maxPixel: 200).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
              }
            }
          }
          NoticeStatus(notice: n)
        }
        .padding(.vertical, 4)
      }
    }
    .listStyle(.plain)
    .overlay { state.overlay(empty: notices.isEmpty, emptyText: "没有群公告", icon: "megaphone") }
    .navigationTitle("群公告")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  private func load() async {
    var req = Qqbridge_V1_ListGroupNoticesRequest()
    req.groupID = groupId
    do {
      notices = try await session.api.contacts.listGroupNotices(request: req, headers: session.api.headers).get().notices
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
  }
}

struct NoticeTag: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
      .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(color)
  }
}

/// 公告下面一行：需要确认的显示自己确认了没有，再加已读人数。
struct NoticeStatus: View {
  let notice: Qqbridge_V1_GroupNotice
  var body: some View {
    HStack(spacing: 10) {
      if notice.confirmRequired {
        HStack(spacing: 3) {
          Image(systemName: notice.readByMe ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
          Text(notice.readByMe ? "已确认" : "需要确认")
        }
        .foregroundStyle(notice.readByMe ? .green : .orange)
      }
      Text("\(notice.readCount) 人已读").foregroundStyle(.secondary)
    }
    .font(.caption)
  }
}

struct NoticeDetailView: View {
  let session: Session
  let notice: Qqbridge_V1_GroupNotice
  @State private var gallery: URLGallery?
  @State private var number: String?
  @State private var profile: ProfileTarget?
  @State private var toast: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(notice.senderName).font(.headline)
            Text(Date(timeIntervalSince1970: TimeInterval(notice.time)).formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if notice.pinned { NoticeTag(text: "置顶", color: .orange) }
        }
        // 链接、号码可以点（和聊天里一样）。
        Text(Linkify.attributed(notice.text))
          .font(.body)
          .textSelection(.enabled)
          .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Linkify.numberScheme, let n = url.host() else { return .systemAction }
            number = n
            return .handled
          })
        ForEach(Array(notice.imageUrls.enumerated()), id: \.offset) { i, url in
          RemoteImage(url: URL(string: url), maxPixel: 1200, fit: true)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { gallery = URLGallery(items: notice.imageUrls.compactMap { URL(string: $0) }.map { .image($0) }, index: i) }
        }
        Divider()
        NoticeStatus(notice: notice)
        if notice.confirmRequired, !notice.readByMe {
          Text("QQ 没有提供确认公告的接口，需要在手机 QQ 里点「确认」。").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding()
    }
    .navigationTitle("群公告")
    .navigationBarTitleDisplayMode(.inline)
    .urlGallery($gallery)
    .modifier(NumberActions(number: $number, onProfile: { profile = ProfileTarget(userId: $0) }, onCopied: { toast = "已复制" }))
    .sheet(item: $profile) { t in
      NavigationStack { UserProfileView(session: session, userId: t.userId, groupMember: nil, asCard: true) }
        .presentationDetents([.medium, .large])
    }
    .overlay(alignment: .top) {
      if let toast {
        Text(toast).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8).glassEffect(.regular, in: Capsule())
          .task { try? await Task.sleep(for: .seconds(1.5)); self.toast = nil }
      }
    }
  }
}

// MARK: - 群相册

struct GroupAlbumsView: View {
  let session: Session
  let groupId: Int64
  @State private var albums: [Qqbridge_V1_GroupAlbum] = []
  @State private var state = LoadState.loading

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
        ForEach(albums, id: \.id) { a in
          NavigationLink { AlbumMediaView(session: session, groupId: groupId, albumId: a.id, title: a.name) } label: {
            VStack(alignment: .leading, spacing: 6) {
              Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { RemoteImage(url: URL(string: a.coverURL), maxPixel: 500) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
              Text(a.name).font(.subheadline.weight(.medium)).lineLimit(1)
              Text("\(a.count) 张 · \(Format.date(a.updatedAt))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .buttonStyle(.plain)
        }
      }
      .padding()
    }
    .overlay { state.overlay(empty: albums.isEmpty, emptyText: "没有群相册", icon: "photo.on.rectangle.angled") }
    .navigationTitle("群相册")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  private func load() async {
    var req = Qqbridge_V1_ListGroupAlbumsRequest()
    req.groupID = groupId
    do {
      albums = try await session.api.contacts.listGroupAlbums(request: req, headers: session.api.headers).get().albums
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
  }
}

/// 一个相册里的照片和视频：按上传日期分组，滑到底继续加载更早的。
struct AlbumMediaView: View {
  let session: Session
  let groupId: Int64
  let albumId: String
  var title: String = ""
  @State private var media: [Qqbridge_V1_GroupAlbumMedia] = []
  @State private var cursor = ""
  @State private var hasMore = true
  @State private var loading = false
  @State private var state = LoadState.loading
  @State private var name = ""
  @State private var gallery: URLGallery?

  private var sections: [(day: String, items: [(index: Int, media: Qqbridge_V1_GroupAlbumMedia)])] {
    var out: [(String, [(Int, Qqbridge_V1_GroupAlbumMedia)])] = []
    for (i, m) in media.enumerated() {
      let day = Format.date(m.time)
      if out.last?.0 == day { out[out.count - 1].1.append((i, m)) } else { out.append((day, [(i, m)])) }
    }
    return out
  }

  var body: some View {
    ScrollView {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2, pinnedViews: [.sectionHeaders]) {
        ForEach(sections, id: \.day) { section in
          Section {
            ForEach(section.items, id: \.media.id) { entry in
              Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { RemoteImage(url: URL(string: entry.media.thumbURL), maxPixel: 400) }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                  if entry.media.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6) }
                }
                .contentShape(Rectangle())
                .onTapGesture { gallery = URLGallery(items: media.map(Self.galleryItem), index: entry.index) }
                .onAppear { if entry.media.id == media.last?.id { Task { await loadMore() } } }
            }
          } header: {
            let uploaders = Array(Set(section.items.map(\.media.uploaderName).filter { !$0.isEmpty })).sorted()
            HStack {
              Text(section.day).font(.footnote.weight(.semibold))
              Spacer()
              if !uploaders.isEmpty { Text(uploaders.prefix(3).joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
          }
        }
      }
      if loading, !media.isEmpty { ProgressView().padding() }
    }
    .overlay { state.overlay(empty: media.isEmpty, emptyText: "相册是空的", icon: "photo") }
    .navigationTitle(title.isEmpty ? name : title)
    .navigationBarTitleDisplayMode(.inline)
    .urlGallery($gallery)
    .task { await loadMore() }
  }

  static func galleryItem(_ m: Qqbridge_V1_GroupAlbumMedia) -> URLGallery.Item {
    if m.isVideo, let v = URL(string: m.videoURL), !m.videoURL.isEmpty { return .video(v) }
    return .image(URL(string: m.url.isEmpty ? m.thumbURL : m.url) ?? URL(string: "about:blank")!)
  }

  private func loadMore() async {
    guard hasMore, !loading else { return }
    loading = true
    defer { loading = false }
    var req = Qqbridge_V1_ListGroupAlbumMediaRequest()
    req.groupID = groupId
    req.albumID = albumId
    req.cursor = cursor
    do {
      let res = try await session.api.contacts.listGroupAlbumMedia(request: req, headers: session.api.headers).get()
      let known = Set(media.map(\.id))
      media += res.media.filter { !known.contains($0.id) }
      cursor = res.nextCursor
      hasMore = res.hasMore_p && !res.nextCursor.isEmpty
      if name.isEmpty { name = res.albumName }
      state = .loaded
    } catch {
      if media.isEmpty { state = .failed(LoadState.describe(error)) }
      hasMore = false
    }
  }
}

// MARK: - 网络图片

/// 按链接显示一张网络图片（缩小解码、内存缓存）。
struct RemoteImage: View {
  let url: URL?
  var maxPixel: CGFloat = 600
  /// true：按比例完整显示（详情页）；false：铺满裁切（格子）。
  var fit = false
  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        if fit {
          Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
          Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        }
      } else {
        ZStack {
          Rectangle().fill(.quaternary)
          if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) } else { ProgressView().controlSize(.small) }
        }
        .frame(minHeight: fit ? 180 : nil)
      }
    }
    .task(id: url) { await load() }
  }

  private func load() async {
    guard let url else { failed = true; return }
    let key = "url:\(url.absoluteString)@\(Int(maxPixel))"
    if let hit = ImageMemoryCache.shared.get(key) { image = hit; return }
    guard let (data, _) = try? await URLSession.shared.data(from: url) else { failed = true; return }
    let limit = maxPixel
    let decoded = await Task.detached { ImageDecoder.downsampled(data: data, maxPixel: limit) }.value
    if let decoded {
      ImageMemoryCache.shared.set(key, decoded)
      image = decoded
    } else {
      failed = true
    }
  }
}

/// 一组网络图片 / 视频的看大图（群公告、群相册）。
struct URLGallery: Identifiable {
  enum Item: Hashable {
    case image(URL)
    case video(URL)
  }

  let id = UUID()
  let items: [Item]
  let index: Int
}

extension View {
  func urlGallery(_ gallery: Binding<URLGallery?>) -> some View {
    fullScreenCover(item: gallery) { g in
      URLGalleryView(gallery: g)
        .presentationBackground(.black)
    }
  }
}

struct URLGalleryView: View {
  let gallery: URLGallery
  @Environment(\.dismiss) private var dismiss
  @State private var current = 0
  @State private var chrome = true

  var body: some View {
    TabView(selection: $current) {
      ForEach(Array(gallery.items.enumerated()), id: \.offset) { i, item in
        Group {
          switch item {
          case .image(let url): URLImagePage(url: url, onTap: { withAnimation { chrome.toggle() } }, onDismiss: { dismiss() })
          case .video(let url): VideoPlayer(player: AVPlayer(url: url))
          }
        }
        .tag(i)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .ignoresSafeArea()
    .overlay(alignment: .top) {
      if chrome {
        HStack {
          if gallery.items.count > 1 {
            Text("\(current + 1) / \(gallery.items.count)")
              .font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(.white)
              .padding(.horizontal, 12).padding(.vertical, 6)
              .background(Capsule().fill(.black.opacity(0.45)))
          }
          Spacer()
          Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
              .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.55)))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .transition(.opacity)
      }
    }
    .statusBarHidden(!chrome)
    .onAppear { current = gallery.index }
  }
}

struct URLImagePage: View {
  let url: URL
  let onTap: () -> Void
  let onDismiss: () -> Void
  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      Color.black
      if let image {
        ZoomableImage(image: image, onTap: onTap, onDismiss: onDismiss)
      } else if failed {
        Label("图片加载失败", systemImage: "photo.badge.exclamationmark").foregroundStyle(.white)
      } else {
        ProgressView().tint(.white).controlSize(.large)
      }
    }
    .task(id: url) {
      guard let (data, _) = try? await URLSession.shared.data(from: url) else { failed = true; return }
      image = await Task.detached { ImageDecoder.downsampled(data: data, maxPixel: 4096) }.value
      if image == nil { failed = true }
    }
  }
}
