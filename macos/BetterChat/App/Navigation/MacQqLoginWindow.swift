import QQBridgeKit
import SwiftUI
import UIKit

/// QQ 掉线后扫码登录：独立的小窗口（「QQ 已掉线」横幅、设置窗口的账号页都开它）。
/// 2026-10-18 用户反馈：以前是主窗口中间的模态表单（旧样式），和其他已经改成 Mac 形式的面板不一致。
/// 同一时间只开一个；登录成功后自己关掉。
@MainActor
enum MacQqLoginWindow {
  static let activityType = "com.xiaomouz.betterchat.mac.qqlogin"
  static let configurationName = "QQLogin"

  static func open() {
    if let session = sessions.first {
      UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
      return
    }
    let activity = NSUserActivity(activityType: activityType)
    activity.targetContentIdentifier = "qqlogin"
    var request = UISceneSessionActivationRequest(role: .windowApplication)
    request.userActivity = activity
    UIApplication.shared.activateSceneSession(for: request) { _ in
      Task { @MainActor in AppModel.shared.showToast(AppToast(text: "无法打开扫码登录窗口，请重试")) }
    }
  }

  // 2026-10-18 实机：代码里新建的场景 configuration.name 读回来是 nil（只有 Info.plist 里声明的 Main 有名字），
  // 所以按场景委托的类型找窗口。
  private static var sessions: [UISceneSession] {
    UIApplication.shared.openSessions.filter { $0.scene?.delegate is MacQqLoginSceneDelegate }
  }

  static func close() {
    for session in sessions {
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
  }
}

@MainActor
final class MacQqLoginSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene, let account = AppModel.shared.session,
          options.userActivities.contains(where: { $0.activityType == MacQqLoginWindow.activityType })
    else {
      // 重启后恢复出来的扫码窗口（或者没登录本 App）：不留着。
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
      return
    }
    scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(format: "SELF == 'qqlogin'")
    scene.sizeRestrictions?.minimumSize = CGSize(width: 380, height: 480)
    scene.sizeRestrictions?.maximumSize = CGSize(width: 520, height: 640)
    scene.sizeRestrictions?.allowsFullScreen = false
    scene.titlebar?.titleVisibility = .visible
    scene.titlebar?.toolbar = nil
    scene.title = "QQ 扫码登录"
    let window = UIWindow(windowScene: scene)
    window.tintColor = .systemBlue
    window.rootViewController = UIHostingController(rootView:
      QqLoginSheet(session: account, onDone: { MacQqLoginWindow.close() })
        .environment(AppModel.shared).environment(\.session, account))
    self.window = window
    window.makeKeyAndVisible()
    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 320, y: 160, width: 400, height: 520)))
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    window?.rootViewController = nil
    window = nil
  }
}
