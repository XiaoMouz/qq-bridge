import QQBridgeKit
import SwiftUI

/// 快速回复浮层：从主会话复制完整草稿独立编辑；关闭时交回，展开时随导航移交文字、提及、回复与附件。
struct MacQuickReplyPage: View {
  let session: Session
  let chatId: Int64
  let onExpand: (Composer) -> Void
  let onClose: (Composer) -> Void
  @State private var composer: Composer

  init(session: Session, chatId: Int64, initialComposer: Composer?, onClose: @escaping (Composer) -> Void, onExpand: @escaping (Composer) -> Void) {
    self.session = session
    self.chatId = chatId
    self.onExpand = onExpand
    self.onClose = onClose
    _composer = State(initialValue: initialComposer?.copyDraft() ?? Composer())
  }
  var body: some View {
    NavigationStack {
      ChatScreen(session: session, chatId: chatId, onExpand: { onExpand(composer) }, suppliedComposer: composer)
    }
    .onDisappear { onClose(composer) }
  }
}
