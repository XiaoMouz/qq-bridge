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
    return await MainActor.run {
      chatId != nil && chatId == model?.openChatId ? [] : [.banner, .list, .sound]
    }
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

  /// 图标角标 = 会提醒的会话（不含免打扰、群助手）的未读数之和，与服务端推送里的角标一致。
  func updateBadge(_ dialogs: [DialogItem]) {
    let count = dialogs.filter { !$0.isMuted }.reduce(0) { $0 + Int($1.dialog.unreadCount) }
    UNUserNotificationCenter.current().setBadgeCount(count)
  }
}
