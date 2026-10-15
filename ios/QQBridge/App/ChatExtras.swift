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

/// 在服务端的完整聊天记录里查找：按搜索键才查，点结果回到聊天里的那条消息；滚到底继续往更早翻。
struct ChatSearchView: View {
  let session: Session
  let chatId: Int64
  @Environment(AppModel.self) private var model
  @State private var query = ""
  @State private var searchPresented = false
  @State private var pager: MessageSearchPager

  init(session: Session, chatId: Int64) {
    self.session = session
    self.chatId = chatId
    _pager = State(initialValue: MessageSearchPager(session: session, chatId: chatId))
  }

  var body: some View {
    #if targetEnvironment(macCatalyst)
    MacChatHistoryView(session: session, chatId: chatId)
    #else
    List {
      ForEach(pager.results, id: \.searchKey) { m in
        Button {
          // Mac 返回聊天后不能让原搜索控制器继续占着导航栏和焦点（2026-10-14 多选取消时复现）。
          searchPresented = false
          model.openMessage(chatId: chatId, seq: m.seq)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(pager.senderName(m)).font(.caption.bold())
              Spacer()
              Text(Format.chatTime(m.time)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(highlighted(Format.preview(m))).font(.subheadline).lineLimit(4)
          }
        }
        .tint(.primary)
        .onAppear { if m.searchKey == pager.results.last?.searchKey { Task { await pager.loadMore() } } }
      }
      if pager.hasMore || pager.loadingMore {
        SearchMoreRow(loading: pager.loadingMore, failed: pager.failed) { Task { await pager.loadMore() } }
      }
    }
    .listStyle(.plain)
    .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索这个会话的聊天记录")
    .onDisappear { searchPresented = false }
    .onSubmit(of: .search) { Task { await pager.search(query) } }
    .onChange(of: query) { _, q in
      if q.trimmingCharacters(in: .whitespaces).isEmpty { pager.reset() }
    }
    .navigationTitle("查找聊天记录")
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if pager.searching {
        ProgressView("正在服务器上查找…")
      } else if let failed = pager.failed, pager.results.isEmpty {
        ContentUnavailableView("查找失败", systemImage: "exclamationmark.triangle", description: Text(failed))
      } else if let searched = pager.searched, pager.results.isEmpty {
        ContentUnavailableView.search(text: searched)
      } else if pager.searched == nil {
        ContentUnavailableView("输入关键词后按搜索", systemImage: "magnifyingglass", description: Text("在服务器上保存的全部聊天记录里查找，点结果回到聊天里的那条消息"))
      }
    }
    #endif
  }

  private func highlighted(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    guard let key = pager.searched, !key.isEmpty else { return out }
    var from = out.startIndex
    while let r = out[from...].range(of: key, options: .caseInsensitive) {
      out[r].foregroundColor = .accentColor
      out[r].font = .subheadline.bold()
      from = r.upperBound
    }
    return out
  }
}

/// 搜索结果末尾：正在加载更早的结果 / 加载失败时点一下重试。
struct SearchMoreRow: View {
  let loading: Bool
  let failed: String?
  let retry: () -> Void

  var body: some View {
    HStack {
      Spacer()
      if loading {
        ProgressView()
      } else if let failed {
        Button("加载失败，点此重试", action: retry).font(.footnote).help(failed)
      } else {
        Button("加载更早的结果", action: retry).font(.footnote)
      }
      Spacer()
    }
    .listRowSeparator(.hidden)
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
  #if targetEnvironment(macCatalyst)
  @State private var mediaList: MacSharedMediaViewModel
  private var items: [Qqbridge_V1_SharedMedia] { mediaList.items }

  init(session: Session, chatId: Int64, mediaService: (any MacSharedMediaService)? = nil) {
    self.session = session
    self.chatId = chatId
    _mediaList = State(initialValue: MacSharedMediaViewModel(service: mediaService ?? MacSessionSharedMediaService(session: session, chatID: chatId)))
  }
  #else
  @State private var items: [Qqbridge_V1_SharedMedia] = []
  @State private var nextBefore: Int64 = 0
  @State private var nextOffset: Int32 = 0
  @State private var done = false
  @State private var loading = false
  #endif
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
    #if targetEnvironment(macCatalyst)
    .overlay { MacSharedMediaEmptyState(model: mediaList, files: tab == .files) }
    #else
    .overlay {
      if items.isEmpty, loading {
        ProgressView()
      } else if items.isEmpty, done {
        ContentUnavailableView(tab == .media ? "没有图片和视频" : "没有文件", systemImage: tab == .media ? "photo.on.rectangle" : "doc")
      }
    }
    #endif
    .mediaViewer(item: $target, session: session, chatId: chatId)
    .quickLookPreview($fileURL)
    .alert("打不开", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), presenting: error) { _ in
      Button("好") { error = nil }
    } message: { Text($0) }
    #if targetEnvironment(macCatalyst)
    .onChange(of: "\(tab.rawValue)|\(sort.rawValue)", initial: true) { _, _ in
      mediaList.select(MacSharedMediaQuery(files: tab == .files, sort: sort.api))
    }
    .onAppear { mediaList.select(MacSharedMediaQuery(files: tab == .files, sort: sort.api)) }
    .onDisappear { mediaList.cancel() }
    #else
    .task(id: "\(tab.rawValue)|\(sort.rawValue)") { await reload() }
    #endif
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
              mediaTile(item)
                .contextMenu {
                  Button("在聊天中查看", systemImage: "text.bubble") { model.openMessage(chatId: chatId, seq: item.seq) }
                }
                .onAppear { reached(item) }
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
      #if targetEnvironment(macCatalyst)
      MacSharedMediaPagination(model: mediaList)
      #endif
    }
  }

  @ViewBuilder private func mediaTile(_ item: Qqbridge_V1_SharedMedia) -> some View {
    #if targetEnvironment(macCatalyst)
    Button { open(item) } label: {
      SharedMediaTile(item: item, chatId: chatId, session: session, requester: requester, showSize: sort == .largest)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(item.kind == .video ? "打开视频" : "查看图片")
    .accessibilityValue("\(senderName(item.senderID)) · \(Format.date(item.time))")
    .help("在独立窗口打开")
    #else
    SharedMediaTile(item: item, chatId: chatId, session: session, requester: requester, showSize: sort == .largest)
      .onTapGesture { open(item) }
    #endif
  }

  private func reached(_ item: Qqbridge_V1_SharedMedia) {
    #if targetEnvironment(macCatalyst)
    mediaList.reached(item)
    #else
    if item.key == items.last?.key { Task { await loadMore() } }
    #endif
  }

  private var fileList: some View {
    List {
      ForEach(sections, id: \.title) { section in
        Section {
          ForEach(section.items, id: \.key) { item in
            fileRow(item)
              .onAppear { reached(item) }
          }
        } header: {
          #if targetEnvironment(macCatalyst)
          if !section.title.isEmpty { Text(section.title) }
          #else
          Text(section.title)
          #endif
        }
      }
      #if targetEnvironment(macCatalyst)
      MacSharedMediaPagination(model: mediaList)
      #endif
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
      // 先登记再请求；服务端还在下载就等它推「下好了」。
      let watch = MediaReady.shared.watch(chatId: chatId, seq: seq, ord: f.media.ord, thumb: false)
      for _ in 0..<6 {
        if let m = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get().media.first {
          if m.state == .stored, !m.sha256.isEmpty { sha = m.sha256; break }
          if m.state == .expired || m.state == .failed || m.state == .skipped { break }
        }
        if let e = await watch.next(timeout: .seconds(300)) {
          if e.state == "stored", !e.sha256.isEmpty { sha = e.sha256; break }
          break
        }
      }
    }
    #if targetEnvironment(macCatalyst)
    guard !sha.isEmpty else { error = "文件已经过期，QQ 上也拿不到了"; return }
    do { fileURL = try await MacDownloads.shared.file(sha: sha, name: f.name, session: session) }
    catch { self.error = error.localizedDescription }
    #else
    guard !sha.isEmpty, let cached = try? await session.media.file(for: sha, chatId: chatId) else {
      error = "文件已经过期，QQ 上也拿不到了"
      return
    }
    let named = FileManager.default.temporaryDirectory.appendingPathComponent(f.name.isEmpty ? cached.lastPathComponent : f.name)
    try? FileManager.default.removeItem(at: named)
    try? FileManager.default.copyItem(at: cached, to: named)
    fileURL = named
    #endif
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

  #if !targetEnvironment(macCatalyst)
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
  #endif
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
    // 视频没有封面：不拿视频文件当图片。
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

  /// 没有缩略图（视频是封面）：请服务端下载，然后订阅本地库里这条消息，下好了自动换上。
  /// 消息本地还没有的先向服务端拉一次（写进本地库后订阅就会推到）。
  private func fetchThumbIfNeeded() async {
    guard displaySha == nil, let m = media, item.kind == .video || (m.state != .expired && m.state != .failed) else { return }
    requester.want(chatId: chatId, seq: item.seq, ord: m.ord, session: session)
    var asked = false
    do {
      for try await msg in session.store.observeMessage(chatId: chatId, seq: item.seq) {
        guard let msg else {
          if !asked {
            asked = true
            _ = await session.sync.fetchMessage(chatId: chatId, seq: item.seq)
          }
          continue
        }
        for seg in msg.segments {
          let info: Qqbridge_V1_MediaInfo? = switch seg.kind {
          case .image(let i): i.media
          case .video(let v): v.media
          default: nil
          }
          if let info, info.ord == m.ord, !info.thumbSha256.isEmpty || (item.kind == .image && info.state == .stored) {
            fresh = info
            return
          }
        }
      }
    } catch {}
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
  #if targetEnvironment(macCatalyst)
  var body: some View {
    MacGroupListPage(service: MacGroupNoticesService(session: session, groupID: groupId),
                     title: "群公告", emptyText: "没有群公告", icon: "megaphone") { notices in
      content(notices)
    }
  }
  #else
  @State private var notices: [Qqbridge_V1_GroupNotice] = []
  @State private var state = LoadState.loading

  var body: some View {
    content(notices)
    .overlay { state.overlay(empty: notices.isEmpty, emptyText: "没有群公告", icon: "megaphone") }
    .navigationTitle("群公告")
    .navigationBarTitleDisplayMode(.inline)
    .platformRefreshable { await load() }
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
  #endif

  private func content(_ notices: [Qqbridge_V1_GroupNotice]) -> some View {
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
            .modifier(MessageBlockAction(title: "查看公告图片 \(i + 1)", value: "共 \(notice.imageUrls.count) 张") {
              gallery = URLGallery(items: notice.imageUrls.compactMap { URL(string: $0) }.map { .image($0) }, index: i)
            })
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
    .profileCard(item: $profile) { t in
      NavigationStack { UserProfileView(session: session, userId: t.userId, groupMember: nil, asCard: true, onClose: { profile = nil }) }
        #if targetEnvironment(macCatalyst)
        .presentationSizing(.form)
        #else
        .presentationDetents([.medium, .large])
        #endif
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
  #if targetEnvironment(macCatalyst)
  var body: some View {
    MacGroupListPage(service: MacGroupAlbumsService(session: session, groupID: groupId),
                     title: "群相册", emptyText: "没有群相册", icon: "photo.on.rectangle.angled") { albums in
      content(albums)
    }
  }
  #else
  @State private var albums: [Qqbridge_V1_GroupAlbum] = []
  @State private var state = LoadState.loading

  var body: some View {
    content(albums)
    .overlay { state.overlay(empty: albums.isEmpty, emptyText: "没有群相册", icon: "photo.on.rectangle.angled") }
    .navigationTitle("群相册")
    .navigationBarTitleDisplayMode(.inline)
    .platformRefreshable { await load() }
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
  #endif

  private func content(_ albums: [Qqbridge_V1_GroupAlbum]) -> some View {
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
  }
}

/// 一个相册里的照片和视频：按上传日期分组，滑到底继续加载更早的。
struct AlbumMediaView: View {
  let session: Session
  let groupId: Int64
  let albumId: String
  var title: String = ""
  #if targetEnvironment(macCatalyst)
  var body: some View {
    MacAlbumMediaView(service: MacSessionAlbumMediaService(session: session, groupID: groupId, albumID: albumId), title: title)
  }
  #else
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
              mediaTile(entry.media)
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

  private func mediaTile(_ item: Qqbridge_V1_GroupAlbumMedia) -> some View {
    Color.clear.aspectRatio(1, contentMode: .fit)
      .overlay { RemoteImage(url: URL(string: item.thumbURL), maxPixel: 400) }
      .clipped()
      .overlay(alignment: .bottomLeading) {
        if item.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(6) }
      }
      .contentShape(Rectangle())
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
  #endif

  static func galleryItem(_ m: Qqbridge_V1_GroupAlbumMedia) -> URLGallery.Item {
    if m.isVideo, let v = URL(string: m.videoURL), !m.videoURL.isEmpty { return .video(v) }
    return .image(URL(string: m.url.isEmpty ? m.thumbURL : m.url) ?? URL(string: "about:blank")!)
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
    #if targetEnvironment(macCatalyst)
    onChange(of: gallery.wrappedValue?.id, initial: true) { _, _ in
      guard let value = gallery.wrappedValue else { return }
      MacMediaWindows.shared.open(.gallery(value))
      gallery.wrappedValue = nil
    }
    #else
    platformFullScreenCover(item: gallery) { g in
      URLGalleryView(gallery: g)
        .presentationBackground(.black)
    }
    #endif
  }
}

struct URLGalleryView: View {
  let gallery: URLGallery
  @Environment(\.dismiss) private var dismiss
  #if targetEnvironment(macCatalyst)
  @Environment(\.macMediaWindow) private var mediaWindow
  #endif
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 初始页在构造时就定好（越界时夹到有效范围），不在 onAppear 里改，避免先闪一下第一张。
  @State private var current: Int
  @State private var chrome = true
  /// 同页重算保留播放器，翻页或关闭立即释放旧页播放器。
  @State private var playback = URLGalleryPlayback()

  init(gallery: URLGallery) {
    self.gallery = gallery
    _current = State(initialValue: min(max(gallery.index, 0), max(gallery.items.count - 1, 0)))
  }

  var body: some View {
    TabView(selection: $current) {
      ForEach(Array(gallery.items.enumerated()), id: \.offset) { i, item in
        Group {
          switch item {
          case .image(let url): URLImagePage(url: url, onTap: { withAnimation { chrome.toggle() } }, onDismiss: close)
          // 不自动播放；非当前页不给播放器，翻走即由 playback 暂停并释放。
          // 播放器从工具栏下方开始，系统播放器自带的顶部按钮（静音、画中画等）不会被画廊工具栏压住。
          case .video:
            VideoPlayer(player: i == current ? playback.player : nil)
              #if targetEnvironment(macCatalyst)
              .overlay(alignment: .bottomTrailing) {
                if i == current, let player = playback.player {
                  MacVideoControlsButton(player: player).frame(width: 40, height: 40).padding(16)
                }
              }
              #endif
              .padding(.top, toolbarHeight)
          }
        }
        .tag(i)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .background(.black, ignoresSafeAreaEdges: .bottom)
    #if targetEnvironment(macCatalyst)
    .ignoresSafeArea(edges: .bottom)
    #else
    .ignoresSafeArea()
    #endif
    .overlay(alignment: .top) {
      if showsChrome && toolbarHeight > 0 {
        HStack(spacing: 8) {
          if gallery.items.count > 1 {
            #if targetEnvironment(macCatalyst)
            circleButton("chevron.left", label: "上一张", help: "上一张（←）", disabled: current == 0) { move(-1) }
            #endif
            Text("\(current + 1) / \(gallery.items.count)")
              .font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(.white)
              .padding(.horizontal, 12).frame(height: 32)
              .background(Capsule().fill(.black.opacity(0.55)))
              .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
              .fixedSize()
            #if targetEnvironment(macCatalyst)
            circleButton("chevron.right", label: "下一张", help: "下一张（→）", disabled: current >= gallery.items.count - 1) { move(1) }
            #endif
          }
          Spacer()
          #if targetEnvironment(macCatalyst)
          if mediaWindow == nil {
            circleButton("xmark", label: "关闭", help: "关闭（Esc）", disabled: false, action: close)
          }
          #else
          circleButton("xmark", label: "关闭", help: "关闭（Esc）", disabled: false, action: close)
          #endif
        }
        .padding(.horizontal, 16)
        .frame(height: toolbarHeight)
        .transition(.opacity)
      }
    }
    .statusBarHidden(!showsChrome)
    #if targetEnvironment(macCatalyst)
    // 与图片 / 视频查看器相同：Esc 关闭，←/→ 翻页（视频页上方向键用于翻页，不再快进快退）。
    // 只有当前页是视频（playback 持有播放器）时才接管空格，图片页不受影响。
    .background(mediaKeyboard)
    .onAppear { mediaWindow?.registerCleanup("gallery", action: playback.close) }
    #endif
    .onChange(of: current, initial: true) { _, index in
      guard gallery.items.indices.contains(index) else { playback.close(); return }
      if case .video(let url) = gallery.items[index] { playback.select(index: index, url: url) }
      else { playback.select(index: index, url: nil) }
    }
    .onDisappear { playback.close() }
  }

  /// 工具栏一行的高度：40 点圆形按钮上下各留 8 点。
  private var toolbarHeight: CGFloat {
    #if targetEnvironment(macCatalyst)
    mediaWindow != nil && gallery.items.count <= 1 ? 0 : 56
    #else
    56
    #endif
  }

  /// 图片页单击可以隐藏工具栏沉浸查看；视频页没有这个手势（点击交给播放器），
  /// 所以视频页始终显示页码、翻页与关闭，鼠标用户不会因为从隐藏状态翻过来而找不到出口。
  private var showsChrome: Bool {
    guard gallery.items.indices.contains(current) else { return chrome }
    if case .video = gallery.items[current] { return true }
    return chrome
  }

  /// 画廊的圆形按钮：与关闭按钮同尺寸、同底色，细白描边保证在纯黑背景上也能看到按钮边界。
  private func circleButton(_ symbol: String, label: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
        .frame(width: 40, height: 40)
        .background(Circle().fill(.black.opacity(0.55)))
        .overlay(Circle().strokeBorder(.white.opacity(0.2)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.35 : 1)
    .accessibilityLabel(label)
    #if targetEnvironment(macCatalyst)
    .help(help)
    #endif
  }

  private func close() {
    playback.close()
    #if targetEnvironment(macCatalyst)
    if let mediaWindow { mediaWindow.close(); return }
    #endif
    dismiss()
  }

  #if targetEnvironment(macCatalyst)
  private var mediaKeyboard: some View {
    let toggle: (() -> Void)? = playback.player == nil ? nil : { togglePlayback() }
    return MacMediaKeyboard(close: close, previous: { move(-1) }, next: { move(1) }, togglePlayback: toggle)
  }

  /// 空格播放 / 暂停当前视频；播完停在末尾时从头播放。不自动播放，只响应用户按键。
  private func togglePlayback() {
    guard let player = playback.player else { return }
    if player.timeControlStatus == .paused {
      if let item = player.currentItem, item.duration.isNumeric, player.currentTime() >= item.duration {
        player.seek(to: .zero)
      }
      player.play()
    } else {
      player.pause()
    }
  }

  private func move(_ offset: Int) {
    let next = current + offset
    guard gallery.items.indices.contains(next) else { return }
    if reduceMotion { current = next }
    else { withAnimation(.easeInOut(duration: 0.2)) { current = next } }
  }
  #endif
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
