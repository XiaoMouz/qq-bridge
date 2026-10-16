import QQBridgeKit
import SwiftUI

struct MacStorageReferencesView: View {
  let session: Session
  let onClose: () -> Void
  @Environment(AppModel.self) private var app
  @State private var model: MacStorageReferencesViewModel
  @State private var titles = ChatTitles()

  init(session: Session, source: StorageChatsView.Source, sha256: String, onClose: @escaping () -> Void,
       service: (any MacStorageReferencesService)? = nil) {
    self.session = session
    self.onClose = onClose
    _model = State(initialValue: MacStorageReferencesViewModel(service: service ??
      MacSessionStorageReferencesService(session: session, source: source, sha256: sha256)))
  }

  var body: some View {
    NavigationStack {
      List(model.chats) { chat in
        let title = titles.title(chat.id, scene: chat.scene, peerId: chat.peerID, session: session)
        Button {
          model.cancel()
          onClose()
          app.pendingChat = chat.id
        } label: {
          HStack(spacing: 12) {
            AvatarView(sha256: titles.avatar(chat.id, session: session), title: title, seed: chat.peerID, size: 34)
            Text(title).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
          .contentShape(Rectangle())
        }
        .tint(.primary)
        .help("打开\(title)")
      }
      .overlay { emptyState }
      // 有内容时的刷新 / 失败提示浮在顶部，不把列表推下去。
      .overlay(alignment: .top) { refreshState }
      .navigationTitle(model.hasLoaded ? "引用会话（\(model.chats.count)）" : "引用会话")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.cancel(); onClose() } }
        ToolbarItem(placement: .topBarTrailing) {
          Button("刷新", systemImage: "arrow.clockwise") { model.reload() }
            .disabled(model.isLoading).help("刷新引用会话")
        }
      }
    }
    .onAppear { model.start() }
    .onDisappear { model.cancel() }
  }

  @ViewBuilder private var emptyState: some View {
    if model.chats.isEmpty {
      if model.isLoading || (!model.hasLoaded && model.error == nil) { ProgressView("正在查找引用…") }
      else if let error = model.error {
        ContentUnavailableView {
          Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: { Text(error) } actions: { Button("重试") { model.reload() } }
      } else { ContentUnavailableView("没有引用会话", systemImage: "bubble.left.and.bubble.right") }
    }
  }

  @ViewBuilder private var refreshState: some View {
    if !model.chats.isEmpty {
      if model.isLoading {
        MacFloatingRefreshing()
      } else if let error = model.error {
        MacFloatingError(message: error) { model.reload() }
      }
    }
  }
}
