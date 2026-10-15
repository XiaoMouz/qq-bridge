import QQBridgeKit
import QQBridgeProto
import QuickLook
import SwiftUI

struct MacStorageItemsView: View {
  let session: Session
  let source: StorageChatsView.Source
  let group: StorageGroup
  let chatID: Int64?
  let title: String
  @State private var list: MacStorageItemsViewModel
  @State private var sharing: StorageItemModel?
  @State private var opener: MacStorageFileViewModel

  init(session: Session, source: StorageChatsView.Source, group: StorageGroup, chatID: Int64?, title: String,
       service: (any MacStorageItemsService)? = nil, fileService: (any MacStorageFileService)? = nil) {
    self.session = session; self.source = source; self.group = group; self.chatID = chatID; self.title = title
    _opener = State(initialValue: MacStorageFileViewModel(service: fileService ?? MacSessionStorageFileService(session: session)))
    _list = State(initialValue: MacStorageItemsViewModel(service: service ?? MacSessionStorageItemsService(
      session: session, source: source, group: group, chatID: chatID)))
  }

  var body: some View {
    ScrollView {
      if !list.items.isEmpty {
        let purged = list.items.filter(\.purged).count
        let stored = list.items.reduce(Int64(0)) { $0 + ($1.purged ? 0 : $1.size) }
        Text("\(list.items.count)\(list.hasMore ? "+" : "") 份 · \(Bytes.text(stored))\(purged > 0 ? " · \(purged) 份原件已清理" : "")")
          .font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
        ForEach(list.items) { item in
          StorageItemCell(item: item, onShared: { sharing = item }, onOpen: { open(item) })
            .overlay { if opener.opening == item.id { ProgressView().padding(8).background(.regularMaterial, in: Circle()) } }
            .onAppear { list.reached(item.id) }
        }
      }
      .padding(.horizontal, 6)
      if !list.items.isEmpty {
        VStack(spacing: 8) {
          if list.isLoading { ProgressView("正在加载更多…") }
          else if let error = list.error {
            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试加载") { list.loadMore() }
          } else if list.hasMore { Button("加载更多") { list.loadMore() } }
        }
        .padding()
      }
    }
    .overlay { emptyState }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .quickLookPreview(Binding(get: { opener.url }, set: { if $0 == nil { opener.cancel() } }))
    .background {
      // 2026-10-15 实机：内部 sheet 的关闭动作已触发却未退出，复用资料卡的窗口级呈现。
      MacFormPresenter(item: $sharing) { item in
        MacStorageReferencesView(session: session, source: source, sha256: item.sha256, onClose: { sharing = nil })
      }
    }
    .alert("无法打开内容", isPresented: Binding(get: { opener.error != nil }, set: { if !$0 { opener.error = nil } })) {
      Button("好", role: .cancel) { opener.error = nil }
    } message: { Text(opener.error ?? "") }
    .onAppear { list.start() }
    .onDisappear { list.cancel(); opener.cancel() }
  }

  @ViewBuilder private var emptyState: some View {
    if list.items.isEmpty {
      if list.isLoading { ProgressView("正在加载…") }
      else if let error = list.error {
        ContentUnavailableView {
          Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: { Text(error) } actions: { Button("重试加载") { list.loadMore() } }
      } else if list.hasLoaded { ContentUnavailableView("没有\(group.name)", systemImage: group.icon) }
    }
  }

  private func open(_ item: StorageItemModel) {
    opener.cancel(); opener.error = nil
    var media = Qqbridge_V1_MediaInfo()
    media.sha256 = item.sha256; media.thumbSha256 = item.thumbSha256 ?? ""
    media.state = item.purged ? .purged : .stored
    switch item.group {
    case .image, .sticker, .video:
      let target = MediaTarget(kind: item.group == .video ? .video : .image, media: media, chatId: item.chatId, seq: item.seq)
      MacMediaWindows.shared.open(.message(target, session, item.chatId))
    default:
      opener.open(item)
    }
  }
}
