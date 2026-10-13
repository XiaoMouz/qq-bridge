// 通讯通知的内容（通知扩展和 App 共用）：用发消息的意图包装通知，系统据此显示发送者头像、右下角 App 图标。
import Intents
import UserNotifications

enum CommunicationContent {
  /// 通知扩展用：先等意图捐赠完成再更新通知内容，失败再试一次。
  /// 以前捐赠不等完成就更新：同一个人连发几条时扩展进程被复用，后面几条常常更新失败，退回成没有头像的普通通知。
  static func makeAsync(_ content: UNNotificationContent) async -> UNNotificationContent? {
    guard let intent = intent(for: content) else { return nil }
    for attempt in 0..<2 {
      let interaction = INInteraction(intent: intent, response: nil)
      interaction.direction = .incoming
      try? await interaction.donate()
      if let updated = try? content.updating(from: intent) { return updated }
      if attempt == 0 { try? await Task.sleep(for: .milliseconds(200)) }
    }
    return nil
  }

  /// 推送里带了发送者：生成发消息的意图（发送者、群名、会话），系统据此画头像。
  static func make(_ content: UNNotificationContent) -> UNNotificationContent? {
    guard let intent = intent(for: content) else { return nil }
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    interaction.donate(completion: nil)
    return try? content.updating(from: intent)
  }

  private static func intent(for content: UNNotificationContent) -> INSendMessageIntent? {
    let info = content.userInfo
    guard let sender = info["sender"] as? [String: Any], let chatId = (info["chatId"] as? NSNumber)?.int64Value else { return nil }
    let senderId = (sender["id"] as? NSNumber)?.stringValue ?? "0"
    let name = (sender["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? content.title
    let image = (sender["avatar"] as? String).flatMap { Data(base64Encoded: $0) }.map { INImage(imageData: $0) }
    let person = INPerson(
      personHandle: INPersonHandle(value: senderId, type: .unknown),
      nameComponents: nil,
      displayName: name,
      image: image,
      contactIdentifier: nil,
      customIdentifier: senderId
    )
    let group = (info["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    // 群聊：收件人要有两个以上，系统才当成群消息（标题显示群名）。
    let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: "我", image: nil, contactIdentifier: nil, customIdentifier: "me", isMe: true)
    let intent = INSendMessageIntent(
      recipients: group != nil ? [me, person] : [me],
      outgoingMessageType: .outgoingMessageText,
      content: content.body,
      speakableGroupName: group.map { INSpeakableString(spokenPhrase: $0) },
      conversationIdentifier: "chat-\(chatId)",
      serviceName: nil,
      sender: person,
      attachments: nil
    )
    return intent
  }
}
