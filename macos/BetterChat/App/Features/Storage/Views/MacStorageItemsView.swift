import QQBridgeKit
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
  @Environment(AppModel.self) private var app

  init(session: Session, source: StorageChatsView.Source, group: StorageGroup, chatID: Int64?, title: String,
       service: (any MacStorageItemsService)? = nil, fileService: (any MacStorageFileService)? = nil) {
    self.session = session; self.source = source; self.group = group; self.chatID = chatID; self.title = title
    _opener = State(initialValue: MacStorageFileViewModel(service: fileService ?? MacSessionStorageFileService(session: session)))
    _list = State(initialValue: MacStorageItemsViewModel(service: service ?? MacSessionStorageItemsService(
      session: session, source: source, group: group, chatID: chatID)))
  }

  var body: some View {
    ScrollView {
      if source == .server {
        StorageQueryBar(query: Binding(get: { list.query }, set: { list.update(query: $0) }), session: session, chatId: chatID, showsSenders: showsSenders)
      }
      if list.query.sort == .sender, let chatID {
        StorageSendersList(session: session, chatId: chatID, group: group) { person in
          var q = list.query
          q.senderMode = .only
          q.senders = [person]
          q.sort = .size
          list.update(query: q)
        }
      }
      if !list.items.isEmpty {
        let purged = list.items.filter(\.purged).count
        let stored = list.items.reduce(Int64(0)) { $0 + ($1.purged ? 0 : $1.size) }
        Text("\(list.items.count)\(list.hasMore ? "+" : "") 份 · \(Bytes.text(stored))\(purged > 0 ? " · \(purged) 份原件已清理" : "")")
          .font(.footnote).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6, pinnedViews: .sectionHeaders) {
        ForEach(StorageSections.make(list.items, sort: list.query.sort)) { section in
          Section {
            ForEach(section.items) { item in cell(item) }
          } header: {
            StorageSectionHeader(section: section).background(.background)
          }
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
    if list.items.isEmpty, list.query.sort != .sender {
      if list.isLoading { ProgressView("正在加载…") }
      else if let error = list.error {
        ContentUnavailableView {
          Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: { Text(error) } actions: { Button("重试加载") { list.loadMore() } }
      } else if list.hasLoaded { ContentUnavailableView("没有\(group.name)", systemImage: group.icon) }
    }
  }

  /// 群聊（服务端的）才能按发送者筛选、分组。
  private var showsSenders: Bool {
    guard source == .server, let chatID, let d = try? session.store.dialog(chatId: chatID) else { return false }
    return d.scene == .group
  }

  private func cell(_ item: StorageItemModel) -> some View {
    StorageItemCell(item: item, onShared: { sharing = item }, onOpen: { open(item) })
      .overlay { if opener.opening == item.id { ProgressView().padding(8).background(.regularMaterial, in: Circle()) } }
      // 和 iOS 一样（863dd85）：右键「在聊天中查看」跳到引用它的那条消息。
      .contextMenu {
        if item.canShowInChat {
          Button("在聊天中查看", systemImage: "text.bubble") { app.openMessage(chatId: item.chatId, seq: item.seq) }
        }
        if item.refChats > 1 {
          Button("被 \(item.refChats) 个会话引用", systemImage: "link") { sharing = item }
        }
      }
      .onAppear { list.reached(item.id) }
  }

  private func open(_ item: StorageItemModel) {
    opener.cancel(); opener.error = nil
    switch item.group {
    case .image, .sticker:
      // 媒体窗口顶栏有「在聊天中查看」；图片能左右翻这一页里的其他图片（同 iOS）。
      var target = item.mediaTarget(.image)
      target.gallery = list.items.filter { $0.group == .image || $0.group == .sticker }.map { $0.mediaTarget(.image) }
      MacMediaWindows.shared.open(.message(target, session, item.chatId))
    case .video:
      MacMediaWindows.shared.open(.message(item.mediaTarget(.video), session, item.chatId))
    default:
      opener.open(item)
    }
  }
}
