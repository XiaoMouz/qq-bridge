// 聊天页：消息列表（UIKit 集合视图，见 ChatCollectionView）+ 玻璃输入栏。
// 数据流：打开时让同步引擎拉首屏 / 补变化 → 观察本地库 → 列表刷新；滑到顶部时往上翻页。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct ChatScreen: View {
  let session: Session
  let chatId: Int64
  @Environment(AppModel.self) private var model
  @State private var items: [ChatItem] = []
  @State private var limit = 60
  @State private var dialog: Qqbridge_V1_Dialog?
  @State private var peer: Qqbridge_V1_Peer?
  @State private var selfUin: Int64 = 0
  @State private var loadingOlder = false
  @State private var reachedStart = false
  @State private var draft = ""
  @State private var sendError: String?
  @FocusState private var inputFocused: Bool

  private var title: String {
    if let p = peer {
      if !p.remark.isEmpty { return p.remark }
      if !p.name.isEmpty { return p.name }
    }
    return dialog.map { String($0.peerID) } ?? ""
  }

  var body: some View {
    ChatCollectionView(
      items: items,
      context: MessageContext(
        selfUin: selfUin,
        isGroup: dialog?.scene == .group,
        qqAccountId: dialog?.qqAccountID ?? 0,
        chatId: chatId,
        store: session.store
      ),
      onReachTop: loadOlder
    )
    .safeAreaBar(edge: .bottom) { inputBar }
    .toolbar(.hidden, for: .tabBar)
    .navigationTitle(title)
    .navigationSubtitle(model.isTyping(chatId) ? "正在输入…" : (dialog?.scene == .group && (peer?.memberCount ?? 0) > 0 ? "\(peer!.memberCount) 人" : ""))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if dialog?.scene == .friend {
        ToolbarItem(placement: .topBarTrailing) {
          Button("语音通话", systemImage: "phone") {}.disabled(true)  // 主动拨打等 G2 指令录制后再做
        }
      }
    }
    .task {
      dialog = try? session.store.dialog(chatId: chatId)
      if let d = dialog { selfUin = (try? session.store.selfUin(qqAccountId: d.qqAccountID)) ?? 0 }
      try? await session.sync.openChat(chatId)
      await setActive(true)
    }
    .task(id: limit) {
      do {
        for try await list in session.store.observeChat(chatId: chatId, limit: limit) { items = list }
      } catch {}
    }
    .task {
      guard let d = try? session.store.dialog(chatId: chatId) else { return }
      do {
        for try await p in session.store.observePeer(for: d) { peer = p }
      } catch {}
    }
    .onDisappear { Task { await setActive(false) } }
    .alert("发送失败", isPresented: .constant(sendError != nil), presenting: sendError) { _ in
      Button("好") { sendError = nil }
    } message: { Text($0) }
  }

  private var inputBar: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("消息", text: $draft, axis: .vertical)
        .lineLimit(1...6)
        .focused($inputFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.body.weight(.semibold))
          .frame(width: 40, height: 40)
      }
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.circle)
      .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draft = ""
    Task {
      do {
        try await session.sender.sendText(text, chatId: chatId)
      } catch {
        sendError = "\(error)"
      }
    }
  }

  /// 往上翻页：本地还有更早的就先放宽窗口，没有了再向服务端要（服务端没有的会现场向 QQ 拉）。
  private func loadOlder() {
    guard !loadingOlder, !reachedStart else { return }
    loadingOlder = true
    Task {
      defer { loadingOlder = false }
      let localCount = (try? session.store.messages(chatId: chatId, limit: limit + 1).count) ?? 0
      if localCount > limit {
        limit += 60
        return
      }
      let got = (try? await session.sync.loadOlder(chatId, limit: 60)) ?? 0
      if got == 0 { reachedStart = true } else { limit += got }
    }
  }

  /// 告诉服务端正在看哪个会话：它的媒体优先下载，头像按需刷新。
  private func setActive(_ active: Bool) async {
    var req = Qqbridge_V1_SetActiveChatRequest()
    req.chatID = active ? chatId : 0
    _ = await session.api.dialogs.setActiveChat(request: req, headers: session.api.headers)
  }
}
