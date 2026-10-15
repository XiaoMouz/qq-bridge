import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 当前会话的搜索是右栏子页面；搜索框属于内容区，不依赖被隐藏的 iPad 导航栏。
struct MacChatHistoryView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var viewModel: MacChatHistoryViewModel
  @State private var focusRequest = UUID()

  init(session: Session, chatId: Int64) {
    self.session = session
    _viewModel = State(initialValue: MacChatHistoryViewModel(chatID: chatId, service: MacSessionChatHistoryService(session: session)))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        MacSidebarSearchField(text: Binding(get: { viewModel.query }, set: { viewModel.updateQuery($0) }),
                              prompt: "搜索这个会话的聊天记录", focusRequest: focusRequest, hasResults: false,
                              identifier: "mac.chat.history.search", submit: { viewModel.search() }, focusResults: { false })
          .frame(height: MacMetrics.searchFieldHeight)
        Button("搜索") { viewModel.search() }
          .disabled(!viewModel.canSearch || viewModel.isSearching)
      }
      .padding(12)
      Divider()
      List {
        ForEach(viewModel.results, id: \.searchKey) { message in
          Button {
            model.openMessage(chatId: viewModel.chatID, seq: message.seq)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(senderName(message)).font(.caption.bold())
                Spacer()
                Text(Format.chatTime(message.time)).font(.caption2).foregroundStyle(.secondary)
              }
              Text(highlighted(Format.preview(message))).font(.subheadline).lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
          }
          .tint(.primary)
        }
        if viewModel.next != nil {
          VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.moreError { Text(error).foregroundStyle(.secondary) }
            if viewModel.isLoadingMore {
              ProgressView("正在加载更多…")
            } else {
              Button(viewModel.moreError == nil ? "加载更多" : "重试加载更多") { viewModel.loadMore() }
            }
          }
          .padding(.vertical, 8)
        }
      }
      .listStyle(.plain)
      .overlay { status }
    }
    .navigationTitle("查找聊天记录")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { focusRequest = UUID() }
    .onDisappear { viewModel.cancel() }
  }

  @ViewBuilder private var status: some View {
    if viewModel.isSearching {
      ProgressView("正在查找…")
    } else if let error = viewModel.error {
      ContentUnavailableView {
        Label("查找失败", systemImage: "exclamationmark.triangle")
      } description: { Text(error) } actions: {
        Button("重试") { viewModel.search() }
      }
    } else if let term = viewModel.searched, viewModel.results.isEmpty {
      ContentUnavailableView.search(text: term)
    } else if viewModel.searched == nil {
      ContentUnavailableView("查找这个会话的消息", systemImage: "magnifyingglass",
                             description: Text("输入关键词后按回车，点击结果可回到对应消息。"))
    }
  }

  private func senderName(_ message: Qqbridge_V1_Message) -> String {
    guard let dialog = try? session.store.dialog(chatId: viewModel.chatID) else { return String(message.senderID) }
    if message.senderID == (try? session.store.selfUin(qqAccountId: dialog.qqAccountID)) { return "我" }
    if !message.senderName.isEmpty { return message.senderName }
    return (try? session.store.userName(qqAccountId: dialog.qqAccountID, userId: message.senderID)) ?? String(message.senderID)
  }

  private func highlighted(_ text: String) -> AttributedString {
    var result = AttributedString(text)
    guard let term = viewModel.searched, !term.isEmpty else { return result }
    var start = result.startIndex
    while let range = result[start...].range(of: term, options: .caseInsensitive) {
      result[range].foregroundColor = .accentColor
      result[range].font = .subheadline.bold()
      start = range.upperBound
    }
    return result
  }
}
