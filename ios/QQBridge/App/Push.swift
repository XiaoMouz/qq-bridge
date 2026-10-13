// 推送：申请通知权限、拿 APNs 令牌交给服务端（RegisterPush）；点通知打开对应会话；
// App 在前台时，正在看的会话不弹通知，其他会话照常弹横幅。
import QQBridgeKit
import QQBridgeProto
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  /// 由 QQBridgeApp 在启动时接上。
  weak var model: AppModel?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // VoIP 推送（来电交给 CallKit）：要在启动时马上注册，被推送拉起时才接得住。
    CallKitBridge.shared.register()
    #if DEBUG
      // 调试：启动参数 -debugCommNotify YES，3 秒后发一条本地的通讯通知（看头像、App 图标的效果；模拟器的推送不走通知扩展）。
      if UserDefaults.standard.bool(forKey: "debugCommNotify") { Self.debugCommunicationNotification() }
    #endif
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    model?.didReceivePushToken(deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    // 模拟器、没有推送权限的签名都会走到这里；不影响其他功能。
    print("APNs registration failed: \(error.localizedDescription)")
  }

  // 用带完成回调的版本，并在主线程上调用回调：async 版本会在后台线程结束，系统随后在后台线程碰 UIKit，直接崩溃。
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
  ) {
    let chatId = Self.chatId(notification.request.content.userInfo)
    let content = notification.request.content
    let title = content.title, body = content.body
    // App 在前台：不弹系统通知；不是正在看的会话就显示 App 内横幅（点开可以快速回复）。
    Task { @MainActor in
      if let model, let chatId, chatId != model.openChatId {
        model.showBanner(InAppBanner(chatId: chatId, title: title, body: body))
      }
      completionHandler([])
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    let chatId = Self.chatId(response.notification.request.content.userInfo)
    Task { @MainActor in
      if let chatId {
        // 冷启动时界面还没接上 model：先记下，接上后再打开。
        if let model { model.pendingChat = chatId } else { pendingChat = chatId }
      }
      completionHandler()
    }
  }

  #if DEBUG
    nonisolated private static func debugCommunicationNotification() {
      let content = UNMutableNotificationContent()
      content.title = "Something"
      content.body = "通讯通知测试"
      content.threadIdentifier = "chat-153"
      let face = Bundle.main.url(forResource: "QQFaces/s14", withExtension: "png").flatMap { try? Data(contentsOf: $0) }
      var sender: [String: Any] = ["id": NSNumber(value: 3889683447), "name": "鳅鳝的G7人-测试中"]
      if let face { sender["avatar"] = face.base64EncodedString() }
      content.userInfo = ["chatId": NSNumber(value: 153), "seq": NSNumber(value: 1), "sender": sender, "group": "Something"]
      let final = CommunicationContent.make(content) ?? content
      let request = UNNotificationRequest(identifier: UUID().uuidString, content: final, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
      UNUserNotificationCenter.current().add(request)
    }
  #endif

  /// 冷启动时点的通知（model 还没接上）。
  var pendingChat: Int64?

  func attach(_ model: AppModel) {
    self.model = model
    if let chatId = pendingChat {
      pendingChat = nil
      model.pendingChat = chatId
    }
  }

  nonisolated private static func chatId(_ info: [AnyHashable: Any]) -> Int64? {
    (info["chatId"] as? NSNumber)?.int64Value
  }
}

extension AppModel {
  /// 登录后调用：问通知权限（只问一次，之后系统记住），并向 APNs 要令牌。
  func registerForPush() {
    Task {
      let center = UNUserNotificationCenter.current()
      let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
      guard granted else { return }
      UIApplication.shared.registerForRemoteNotifications()
    }
  }

  /// VoIP 推送的令牌（PushKit）：来电时服务端发 VoIP 推送，App 交给 CallKit。
  func didReceiveVoipToken(_ hex: String) {
    guard let session else { return }
    var req = Qqbridge_V1_RegisterPushRequest()
    req.apnsVoipToken = hex
    #if DEBUG
      req.environment = .sandbox
    #else
      req.environment = .production
    #endif
    Task { _ = await session.api.auth.registerPush(request: req, headers: session.api.headers) }
  }

  func didReceivePushToken(_ hex: String) {
    guard let session else { return }
    var req = Qqbridge_V1_RegisterPushRequest()
    req.apnsToken = hex
    // Debug 包用开发证书签名，令牌属于 sandbox；TestFlight / App Store 的是 production。
    #if DEBUG
      req.environment = .sandbox
    #else
      req.environment = .production
    #endif
    Task { _ = await session.api.auth.registerPush(request: req, headers: session.api.headers) }
  }

  /// 角标（图标和"消息"标签）：与服务端推送里的角标一致，见 DialogItem.badgeCount。
  /// 顺带收掉已经读完的会话的系统通知（在这里看了、在 QQ 或别的设备上读了都算）。
  func updateBadge(_ dialogs: [DialogItem]) {
    let count = dialogs.reduce(0) { $0 + $1.badgeCount }
    if count != unreadBadge { unreadBadge = count }
    UNUserNotificationCenter.current().setBadgeCount(count)
    let read = Set(dialogs.filter { $0.dialog.unreadCount == 0 }.map(\.id))
    if !read.isEmpty { clearNotifications(where: { read.contains($0) }) }
  }

  /// 收掉某个会话已经显示的系统通知。
  func clearNotifications(chatId: Int64) {
    clearNotifications(where: { $0 == chatId })
  }

  nonisolated private func clearNotifications(where match: @escaping @Sendable (Int64) -> Bool) {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { list in
      let ids = list.compactMap { n -> String? in
        guard let id = (n.request.content.userInfo["chatId"] as? NSNumber)?.int64Value, match(id) else { return nil }
        return n.request.identifier
      }
      if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
  }
}

extension DialogItem {
  /// 算进角标的未读：会提醒的会话算全部未读；免打扰、群助手、只提醒 @我 的会话只算 @我 和回复我。@全体成员 不单独算。
  var badgeCount: Int {
    if isMuted || dialog.notifyPolicy == "mentions" { return Int(dialog.unreadMentions + dialog.unreadReplies) }
    return Int(dialog.unreadCount)
  }
}

/// App 内横幅：前台收到别的会话的消息时显示在顶部。
struct InAppBanner: Identifiable, Equatable {
  let id = UUID()
  let chatId: Int64
  let title: String
  let body: String
}

extension AppModel {
  func showBanner(_ banner: InAppBanner) {
    self.banner = banner
    Task {
      try? await Task.sleep(for: .seconds(4))
      if self.banner?.id == banner.id { self.banner = nil }
    }
  }
}

/// 屏幕上的一个聊天页。
struct VisibleChat: Equatable {
  let token: UUID
  let chatId: Int64
}
