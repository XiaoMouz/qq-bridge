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
    contentHandler(CommunicationContent.make(request.content) ?? request.content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let original { contentHandler?(original) }
  }
}
