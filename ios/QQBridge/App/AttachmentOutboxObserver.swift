import QQBridgeKit
import SwiftUI

/// 每次出现都订阅当前快照；快速回复移交或页面离开期间完成的发送不会漏掉。
struct AttachmentOutboxObserver: ViewModifier {
  let composer: Composer
  let store: LocalStore
  let chatId: Int64

  private struct Key: Equatable {
    let queue: ObjectIdentifier
    let ids: [Int64]
    let isSending: Bool
  }

  func body(content: Content) -> some View {
    content.task(id: Key(queue: ObjectIdentifier(composer.attachmentQueue), ids: composer.attachments.map(\.clientRandomId), isSending: composer.attachmentQueue.isSending)) {
      await AttachmentSending.observe(store: store, chatId: chatId, composer: composer)
    }
  }
}
