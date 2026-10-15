import QQBridgeKit
import SwiftUI

struct MacStorageChatsView: View {
  let session: Session
  let source: StorageChatsView.Source
  let group: StorageGroup
  let allMedia: Bool
  @Environment(AppModel.self) private var app
  @State private var model: MacStorageSummaryModel<[MacStorageChat]>
  @State private var titles = ChatTitles()

  init(session: Session, source: StorageChatsView.Source, group: StorageGroup, allMedia: Bool,
       fetch: (@MainActor () async throws -> [MacStorageChat])? = nil) {
    self.session = session; self.source = source; self.group = group; self.allMedia = allMedia
    let service = MacStorageSummaryService(session: session)
    _model = State(initialValue: MacStorageSummaryModel(fetch: fetch ?? {
      try await service.chats(source: source, group: group, allMedia: allMedia)
    }))
  }

  var body: some View {
    List {
      if let chats = model.value, !chats.isEmpty {
        let total = chats.reduce(Int64(0)) { $0 + $1.bytes }
        let maxBytes = max(chats.map(\.bytes).max() ?? 1, 1)
        Section {
          LabeledContent("合计", value: Bytes.text(total))
          if source == .server, group == .message {
            Text("消息按每条在数据库里的大小算（文字、消息段和原始数据），数据量大时第一次统计要几秒。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("\(chats.count) 个会话") {
          ForEach(chats) { chat in
            let title = chat.id == 0 ? "不属于会话（头像等）" : titles.title(chat.id, scene: chat.scene, peerId: chat.peerID, session: session)
            if group == .message {
              Button { app.pendingChat = chat.id } label: { row(chat, title: title, total: total, maxBytes: maxBytes) }
                .tint(.primary).disabled(chat.id <= 0)
            } else {
              NavigationLink {
                if allMedia { ChatStorageView(session: session, chatId: chat.id, title: title) }
                else { StorageItemsView(session: session, source: source, group: group, chatId: chat.id, title: title) }
              } label: { row(chat, title: title, total: total, maxBytes: maxBytes) }
            }
          }
        }
      }
    }
    .overlay {
      if let chats = model.value, chats.isEmpty, !model.isLoading, model.error == nil {
        ContentUnavailableView("没有\(allMedia ? "媒体" : group.name)", systemImage: group.icon)
      }
    }
    .navigationTitle(allMedia ? "占用最多的会话" : group.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if group != .message, !allMedia {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink("全部") {
            StorageItemsView(session: session, source: source, group: group, chatId: nil, title: "全部\(group.name)")
          }
        }
      }
    }
    .modifier(MacStorageSummaryStatus(model: model))
  }

  private func row(_ chat: MacStorageChat, title: String, total: Int64, maxBytes: Int64) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        AvatarView(sha256: titles.avatar(chat.id, session: session), title: title, seed: chat.peerID, size: 28)
        Text(title).lineLimit(1)
        Spacer()
        VStack(alignment: .trailing, spacing: 0) {
          Text(Bytes.text(chat.bytes)).monospacedDigit()
          Text("\(chat.count) \(group == .message ? "条" : "份") · \(StorageMath.percent(chat.bytes, of: total))")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      GeometryReader { geometry in
        Capsule().fill(group.color.gradient)
          .frame(width: max(4, geometry.size.width * CGFloat(Double(chat.bytes) / Double(maxBytes))))
      }.frame(height: 5)
    }
  }
}
