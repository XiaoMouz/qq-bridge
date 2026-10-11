// App 内横幅和快速回复：前台收到别的会话的消息时顶部弹一条横幅（不发系统通知），
// 点开是浮层：最近几条消息 + 输入框，可以直接回，也可以"打开会话"进完整聊天页。上划横幅收起。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct InAppBannerView: View {
  let banner: InAppBanner
  let onTap: () -> Void
  let onDismiss: () -> Void
  @State private var drag: CGFloat = 0

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "bubble.left.fill").foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(banner.title).font(.subheadline.bold()).lineLimit(1)
        Text(banner.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .padding(.horizontal, 10)
    .offset(y: min(0, drag))
    .contentShape(Rectangle())
    .onTapGesture(perform: onTap)
    .gesture(
      DragGesture()
        .onChanged { drag = $0.translation.height }
        .onEnded { v in
          if v.translation.height < -30 { onDismiss() } else { withAnimation(.spring) { drag = 0 } }
        }
    )
  }
}

struct QuickReplyView: View {
  let session: Session
  let chatId: Int64
  let onOpen: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var items: [ChatItem] = []
  @State private var dialog: DialogItem?
  @State private var text = ""
  @State private var sending = false
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(messages, id: \.seq) { m in
                VStack(alignment: .leading, spacing: 2) {
                  Text(sender(m)).font(.caption.bold()).foregroundStyle(.secondary)
                  Text(Format.preview(m)).font(.body)
                }
                .id(m.seq)
              }
            }
            .padding()
          }
          .onChange(of: messages.last?.seq) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
          .onAppear { if let last = messages.last?.seq { proxy.scrollTo(last, anchor: .bottom) } }
        }
        HStack(alignment: .bottom, spacing: 8) {
          TextField("回复", text: $text, axis: .vertical)
            .lineLimit(1...4)
            .focused($focused)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
          Button(action: send) {
            Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
              .frame(width: 36, height: 36)
              .background(Circle().fill(Color.accentColor))
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding(12)
      }
      .navigationTitle(dialog?.title ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("打开会话", action: onOpen) }
      }
    }
    .task {
      focused = true
      try? await session.sync.openChat(chatId)
    }
    .task {
      do {
        for try await list in session.store.observeChat(chatId: chatId, limit: 15) { items = list }
      } catch {}
    }
    .task {
      do {
        for try await list in session.store.observeDialogs(limit: 5000) { dialog = list.first { $0.id == chatId } }
      } catch {}
    }
  }

  private var messages: [Qqbridge_V1_Message] {
    items.compactMap { if case .message(let m) = $0 { m } else { nil } }
  }

  private func sender(_ m: Qqbridge_V1_Message) -> String {
    let selfUin = (try? session.store.selfUin(qqAccountId: dialog?.dialog.qqAccountID ?? 0)) ?? 0
    if m.senderID == selfUin { return "我" }
    if !m.senderName.isEmpty { return m.senderName }
    return (try? session.store.userName(qqAccountId: dialog?.dialog.qqAccountID ?? 0, userId: m.senderID)) ?? String(m.senderID)
  }

  private func send() {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    text = ""
    sending = true
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.text = body
    Task {
      defer { sending = false }
      try? await session.sender.send(chatId: chatId, segments: [seg])
      // 回完了就标已读（和在会话里回复一样）。
      if let last = messages.last?.seq { _ = try? await session.api.markRead(chatId: chatId, maxSeq: last) }
    }
  }
}
