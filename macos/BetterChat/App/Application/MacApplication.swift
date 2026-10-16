import UIKit
import SwiftUI
import UserNotifications

@main
@MainActor
final class MacAppDelegate: UIResponder, UIApplicationDelegate {
  /// 测试宿主只加载真实类型，不恢复账号、不注册推送，也不访问用户数据库。
  static var runsStateTests: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["BETTERCHAT_STATE_TESTS"] == "1"
    #else
    false
    #endif
  }
  private let notifications = AppDelegate()
  /// 应用唯一的命令路由；菜单、快捷键与根视图都经它找到当前工作区。
  let router = MacCommandRouter()

  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    if Self.runsStateTests { return true }
    notifications.attach(AppModel.shared)
    router.workspaceChanged = { UIMenuSystem.main.setNeedsRebuild() }
    MacUpdater.start()
    return notifications.application(application, didFinishLaunchingWithOptions: options)
  }
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let media = options.userActivities.contains { $0.activityType == MacMediaWindows.activityType }
      || session.configuration.name == MacMediaWindows.configurationName
    let settings = options.userActivities.contains { $0.activityType == MacSettingsWindow.activityType }
      || session.configuration.name == MacSettingsWindow.configurationName
    if settings {
      let configuration = UISceneConfiguration(name: MacSettingsWindow.configurationName, sessionRole: session.role)
      configuration.delegateClass = MacSettingsSceneDelegate.self
      return configuration
    }
    let quickReply = options.userActivities.contains { $0.activityType == MacQuickReplyWindow.activityType }
      || session.configuration.name == MacQuickReplyWindow.configurationName
    if quickReply {
      let configuration = UISceneConfiguration(name: MacQuickReplyWindow.configurationName, sessionRole: session.role)
      configuration.delegateClass = MacQuickReplySceneDelegate.self
      return configuration
    }
    let configuration = UISceneConfiguration(name: media ? MacMediaWindows.configurationName : "Main", sessionRole: session.role)
    configuration.delegateClass = media ? MacMediaSceneDelegate.self : MacSceneDelegate.self
    return configuration
  }
  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    notifications.application(application, didRegisterForRemoteNotificationsWithDeviceToken: token)
  }
  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    notifications.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
  /// 已读同步的后台推送：交给共用的 AppDelegate 收掉已读的通知。
  nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                               fetchCompletionHandler completionHandler: @escaping @Sendable (UIBackgroundFetchResult) -> Void) {
    guard let chatId = (userInfo["readChat"] as? NSNumber)?.int64Value,
      let seq = (userInfo["readSeq"] as? NSNumber)?.int64Value
    else {
      completionHandler(.noData)
      return
    }
    let badge = (userInfo["badge"] as? NSNumber)?.intValue
    AppDelegate.clearReadNotifications([chatId: seq]) {
      if let badge { UNUserNotificationCenter.current().setBadgeCount(badge) }
      DispatchQueue.main.async { completionHandler(.newData) }
    }
  }
  override func buildMenu(with builder: any UIMenuBuilder) {
    super.buildMenu(with: builder)
    guard builder.system == .main else { return }
    MacMenuBuilder(router: router).build(with: builder)
  }
}

@MainActor
final class MacSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene,
          let router = (UIApplication.shared.delegate as? MacAppDelegate)?.router else { return }
    if MacAppDelegate.runsStateTests {
      let window = UIWindow(windowScene: scene)
      window.rootViewController = UIViewController()
      self.window = window
      window.makeKeyAndVisible()
      return
    }
    // 由 UINavigationBar 的 Mac 行为统一承载两栏工具，窗口标题不再另占一行。
    scene.titlebar?.titleVisibility = .visible
    scene.titlebar?.toolbarStyle = .unified
    scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(format: "SELF == nil OR NOT (SELF BEGINSWITH 'media:' OR SELF BEGINSWITH 'quickreply:' OR SELF == 'settings')")
    scene.sizeRestrictions?.minimumSize = MacMetrics.minimumWindow
    let window = MacWindow(windowScene: scene, router: router)
    window.tintColor = .systemBlue
    window.rootViewController = UIHostingController(rootView: MacRootView(router: router).environment(AppModel.shared))
    self.window = window
    scene.title = "BetterChat"
    window.makeKeyAndVisible()
    AppModel.shared.launch()
  }
  // 切换到其他 Mac 应用时，仍保持消息与通话同步。
  func sceneDidBecomeActive(_ scene: UIScene) {
    if MacAppDelegate.runsStateTests { return }
    AppModel.shared.setActive(true)
    // 2026-10-14 实测：在系统设置开启通知后，回到 App 需重新登记普通推送。
    // 这里只读取已有授权，不在每次切回窗口时弹出权限请求。
    Task {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      guard AppModel.shared.session != nil,
            [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
      UIApplication.shared.registerForRemoteNotifications()
    }
  }
}
