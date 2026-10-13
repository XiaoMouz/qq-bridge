// 群资料里的群公告、群精华（群文件见 GroupFilesView.swift）。列表打开时当场向 QQ 拉（QQ 掉线时看不了）。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct GroupEssenceView: View {
  let session: Session
  let groupId: Int64
  let chatId: Int64
  @State private var items: [Qqbridge_V1_GroupEssence] = []
  @State private var state = LoadState.loading
  @State private var media: MediaTarget?
  @State private var requester = MediaRequester()

  /// 存档里的图片还没有缩略图（按需的、没下载的）。
  private var waitingForThumbs: Bool {
    items.contains { e in
      e.hasMessage && e.message.segments.contains { seg in
        if case .image(let i) = seg.kind { i.media.thumbSha256.isEmpty && i.media.state != .stored && i.media.state != .expired && i.media.state != .failed } else { false }
      }
    }
  }

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
              MediaThumb(media: i.media, width: i.width, height: i.height, chatId: chatId, onNeedThumb: {
                requester.want(chatId: chatId, seq: e.seq, ord: i.media.ord, session: session)
              })
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
    .task {
      await load()
      // 图片缩略图刚开始下载：等服务端推「下好了」再重新拉一次列表，不用退出再进。
      let watch = MediaReady.shared.watch(chatId: chatId, seqs: Set(items.map(\.seq)))
      for _ in 0..<50 where waitingForThumbs {
        guard await watch.next() != nil else { break }
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        await load()
      }
    }
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
