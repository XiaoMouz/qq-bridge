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
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    model?.didReceivePushToken(deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    // 模拟器、没有推送权限的签名都会走到这里；不影响其他功能。
    print("APNs registration failed: \(error.localizedDescription)")
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let chatId = Self.chatId(notification.request.content.userInfo)
    let content = notification.request.content
    let title = content.title, body = content.body
    // App 在前台：不弹系统通知；不是正在看的会话就显示 App 内横幅（点开可以快速回复）。
    await MainActor.run {
      guard let model, let chatId, chatId != model.openChatId else { return }
      model.showBanner(InAppBanner(chatId: chatId, title: title, body: body))
    }
    return []
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard let chatId = Self.chatId(response.notification.request.content.userInfo) else { return }
    await MainActor.run { model?.pendingChat = chatId }
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
  func updateBadge(_ dialogs: [DialogItem]) {
    let count = dialogs.reduce(0) { $0 + $1.badgeCount }
    if count != unreadBadge { unreadBadge = count }
    UNUserNotificationCenter.current().setBadgeCount(count)
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
