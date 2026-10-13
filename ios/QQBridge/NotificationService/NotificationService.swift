// 通知扩展：把服务端推送的新消息做成「通讯通知」——左边是发送者头像，右下角是 App 图标（和信息、微信一样）。
// 头像由服务端缩成 64px 小图直接放在推送里（sender.avatar，base64），这里不用联网、不用登录信息。
import Intents
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var original: UNNotificationContent?

  override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    self.contentHandler = contentHandler
    original = request.content
    // 通知扩展里没有并发访问这几个对象（同一条通知只在这里处理）。
    nonisolated(unsafe) let content = request.content
    nonisolated(unsafe) let handler = contentHandler
    nonisolated(unsafe) let me = self
    Task {
      nonisolated(unsafe) let updated = await CommunicationContent.makeAsync(content)
      me.finish(updated ?? content, handler)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let original, let handler = contentHandler { finish(original, handler) }
  }

  /// 只交一次（超时和正常完成可能前后脚到）。
  private let lock = NSLock()
  private var delivered = false

  private func finish(_ content: UNNotificationContent, _ handler: (UNNotificationContent) -> Void) {
    lock.lock()
    let first = !delivered
    delivered = true
    lock.unlock()
    if first { handler(content) }
  }
}
