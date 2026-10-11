// 群资料里的群公告、群精华、群文件。列表打开时当场向 QQ 拉（QQ 掉线时看不了）；群文件点开时服务端先下载再用 QuickLook 打开。
import QQBridgeKit
import QQBridgeProto
import QuickLook
import SwiftUI

struct GroupNoticesView: View {
  let session: Session
  let groupId: Int64
  @State private var notices: [Qqbridge_V1_GroupNotice] = []
  @State private var state = LoadState.loading

  var body: some View {
    List(notices, id: \.id) { n in
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(n.senderName).font(.subheadline.bold())
          Spacer()
          Text(Format.date(n.time)).font(.caption).foregroundStyle(.secondary)
        }
        Text(n.text).textSelection(.enabled)
        ForEach(n.imageUrls, id: \.self) { url in
          AsyncImage(url: URL(string: url)) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 160)
          }
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        HStack(spacing: 12) {
          if n.confirmRequired { Label("需确认", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.orange) }
          Text("\(n.readCount) 人已读").font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }
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

struct GroupEssenceView: View {
  let session: Session
  let groupId: Int64
  let chatId: Int64
  @State private var items: [Qqbridge_V1_GroupEssence] = []
  @State private var state = LoadState.loading
  @State private var media: MediaTarget?

  var body: some View {
    List(items, id: \.seq) { e in
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(e.senderName).font(.subheadline.bold())
          Spacer()
          Text(Format.date(e.time)).font(.caption).foregroundStyle(.secondary)
        }
        if e.hasMessage {
          // 存档里有原消息：文字和图片都用存档的（图片会动、能看原图）。
          let text = e.message.segments.compactMap { seg -> String? in if case .text(let t) = seg.kind { t.text } else { nil } }.joined()
          if !text.isEmpty { Text(text).textSelection(.enabled) }
          ForEach(Array(e.message.segments.enumerated()), id: \.offset) { _, seg in
            if case .image(let i) = seg.kind {
              MediaThumb(media: i.media, width: i.width, height: i.height, chatId: chatId)
                .onTapGesture { media = MediaTarget(kind: .image, media: i.media, chatId: chatId, seq: e.seq) }
            }
          }
          if text.isEmpty, !e.message.segments.contains(where: { if case .image = $0.kind { true } else { false } }) {
            Text(Format.preview(e.message)).foregroundStyle(.secondary)
          }
        } else {
          if !e.text.isEmpty { Text(e.text).textSelection(.enabled) }
          ForEach(e.imageUrls, id: \.self) { url in
            AsyncImage(url: URL(string: url)) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: {
              RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 160)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
          }
        }
        Text("\(e.operatorName) 设为精华").font(.caption).foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
    .overlay { state.overlay(empty: items.isEmpty, emptyText: "没有群精华", icon: "star") }
    .navigationTitle("群精华")
    .navigationBarTitleDisplayMode(.inline)
    .mediaViewer(item: $media, session: session, chatId: chatId)
    .refreshable { await load() }
    .task { await load() }
  }

  private func load() async {
    var req = Qqbridge_V1_ListGroupEssenceRequest()
    req.groupID = groupId
    do {
      items = try await session.api.contacts.listGroupEssence(request: req, headers: session.api.headers).get().items
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
  }
}

struct GroupFilesView: View {
  let session: Session
  let groupId: Int64
  var folderId = ""
  var title = "群文件"
  @State private var folders: [Qqbridge_V1_GroupFolder] = []
  @State private var files: [Qqbridge_V1_GroupFile] = []
  @State private var state = LoadState.loading
  @State private var opening: String?
  @State private var preview: URL?
  @State private var error: String?

  var body: some View {
    List {
      ForEach(folders, id: \.id) { f in
        NavigationLink {
          GroupFilesView(session: session, groupId: groupId, folderId: f.id, title: f.name)
        } label: {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(f.name)
              Text("\(f.fileCount) 个文件").font(.caption).foregroundStyle(.secondary)
            }
          } icon: { Image(systemName: "folder.fill").foregroundStyle(.tint) }
        }
      }
      ForEach(files, id: \.id) { f in
        Button { Task { await open(f) } } label: {
          HStack(spacing: 12) {
            Image(systemName: Self.icon(f.name)).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
              Text(f.name).lineLimit(2).foregroundStyle(.primary)
              Text(detail(f)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if opening == f.id {
              ProgressView()
            } else if !f.sha256.isEmpty {
              Image(systemName: "checkmark.icloud").foregroundStyle(.secondary)
            }
          }
        }
        .tint(.primary)
        .disabled(opening != nil)
      }
    }
    .overlay { state.overlay(empty: folders.isEmpty && files.isEmpty, emptyText: "没有群文件", icon: "doc") }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .quickLookPreview($preview)
    .alert("打不开", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), presenting: error) { _ in
      Button("好") { error = nil }
    } message: { Text($0) }
    .refreshable { await load() }
    .task { await load() }
  }

  private func detail(_ f: Qqbridge_V1_GroupFile) -> String {
    var parts = [ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)]
    if !f.uploaderName.isEmpty { parts.append(f.uploaderName) }
    if f.modifyTime > 0 { parts.append(Format.date(f.modifyTime)) }
    if f.deadTime > 0 { parts.append("\(Format.date(f.deadTime)) 过期") }
    return parts.joined(separator: " · ")
  }

  private func load() async {
    var req = Qqbridge_V1_ListGroupFilesRequest()
    req.groupID = groupId
    req.folderID = folderId
    do {
      let res = try await session.api.contacts.listGroupFiles(request: req, headers: session.api.headers).get()
      folders = res.folders
      files = res.files
      state = .loaded
    } catch {
      state = .failed(LoadState.describe(error))
    }
  }

  /// 服务端没有就先让它从 QQ 下载，再下到手机上用 QuickLook 打开（保存、分享在 QuickLook 里）。
  private func open(_ f: Qqbridge_V1_GroupFile) async {
    opening = f.id
    defer { opening = nil }
    do {
      var sha = f.sha256
      if sha.isEmpty {
        var req = Qqbridge_V1_FetchGroupFileRequest()
        req.groupID = groupId
        req.fileID = f.id
        req.busid = f.busid
        req.name = f.name
        sha = try await session.api.contacts.fetchGroupFile(request: req, headers: session.api.headers).get().sha256
        if let i = files.firstIndex(where: { $0.id == f.id }) { files[i].sha256 = sha }
      }
      let cached = try await session.media.file(for: sha, chatId: nil)
      let named = FileManager.default.temporaryDirectory.appendingPathComponent(f.name.isEmpty ? sha : f.name)
      try? FileManager.default.removeItem(at: named)
      try FileManager.default.copyItem(at: cached, to: named)
      preview = named
    } catch {
      self.error = LoadState.describe(error)
    }
  }

  static func icon(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "gif", "heic", "webp": "photo"
    case "mp4", "mov", "mkv", "avi": "film"
    case "mp3", "m4a", "wav", "flac", "aac": "music.note"
    case "zip", "rar", "7z", "tar", "gz": "doc.zipper"
    case "pdf": "doc.richtext"
    case "doc", "docx", "txt", "md", "pages": "doc.text"
    case "xls", "xlsx", "csv", "numbers": "tablecells"
    case "ppt", "pptx", "key": "rectangle.on.rectangle"
    case "apk", "ipa", "exe", "dmg": "shippingbox"
    default: "doc"
    }
  }
}

/// 列表页的加载状态和对应的提示。
enum LoadState {
  case loading, loaded, failed(String)

  @ViewBuilder func overlay(empty: Bool, emptyText: String, icon: String) -> some View {
    switch self {
    case .loading: ProgressView()
    case .failed(let message): ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(message))
    case .loaded: if empty { ContentUnavailableView(emptyText, systemImage: icon) }
    }
  }

  static func describe(_ error: Error) -> String {
    if let e = error as? APIError {
      switch e.code {
      case .unavailable: return "QQ 掉线了，重新登录后再试"
      case .failedPrecondition: return "QQ 上已经拿不到了（可能已过期）"
      default: return e.message
      }
    }
    return error.localizedDescription
  }
}
