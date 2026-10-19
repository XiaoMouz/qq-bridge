import QQBridgeKit
import SwiftUI
import UIKit

/// 快速回复：独立的小窗口（点新消息横幅、会话列表右键「快速回复」）。
/// 2026-10-17 按 macOS 习惯改：以前是主窗口里的模态表单，整个窗口变暗、不能操作别处；
/// 现在是能拖动的小窗口，不挡主窗口，一个会话一个；关窗口时草稿交回主会话，「打开完整会话」在主窗口打开并关掉小窗口。
@MainActor
enum MacQuickReplyWindow {
  static let activityType = "com.xiaomouz.betterchat.mac.quickreply"
  static let configurationName = "QuickReply"

  static func open(_ chatId: Int64) {
    if let session = UIApplication.shared.openSessions.first(where: {
      // 按场景委托找：代码里新建的场景 configuration.name 读回来是 nil（2026-10-18 实机）。
      ($0.scene?.delegate as? MacQuickReplySceneDelegate)?.chatId == chatId
    }) {
      UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
      return
    }
    let activity = NSUserActivity(activityType: activityType)
    activity.userInfo = ["chatId": NSNumber(value: chatId)]
    activity.targetContentIdentifier = "quickreply:\(chatId)"
    var request = UISceneSessionActivationRequest(role: .windowApplication)
    request.userActivity = activity
    UIApplication.shared.activateSceneSession(for: request) { _ in
      Task { @MainActor in AppModel.shared.showToast(AppToast(text: "无法打开快速回复，请重试")) }
    }
  }

  /// 退出登录：草稿依赖的账号会话失效，全部关掉。
  static func closeAll() {
    for session in UIApplication.shared.openSessions where session.scene?.delegate is MacQuickReplySceneDelegate {
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
  }
}

@MainActor
final class MacQuickReplySceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private(set) var chatId: Int64?
  private var composer: Composer?

  private var router: MacCommandRouter? { (UIApplication.shared.delegate as? MacAppDelegate)?.router }

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    MacWindowKind.mark(session, MacQuickReplyWindow.configurationName)
    guard let scene = scene as? UIWindowScene,
          let id = (options.userActivities.first { $0.activityType == MacQuickReplyWindow.activityType }?
            .userInfo?["chatId"] as? NSNumber)?.int64Value,
          let account = AppModel.shared.session
    else {
      // 重启后恢复出来的快速回复窗口：没有对应的会话请求，直接关掉。
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
      return
    }
    chatId = id
    scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(format: "SELF == %@", "quickreply:\(id)")
    scene.sizeRestrictions?.minimumSize = CGSize(width: 360, height: 420)
    // 标题栏写会话名，几个快速回复窗口同时开着也分得清。
    scene.titlebar?.titleVisibility = .visible
    scene.titlebar?.toolbar = nil
    scene.title = (try? account.store.dialogItems(limit: 5000))?.first { $0.id == id }?.title ?? "快速回复"
    let router = router
    let page = MacQuickReplyPage(session: account, chatId: id, initialComposer: router?.workspace?.draftComposer(for: id),
      onClose: { [weak self] composer in self?.composer = composer },
      onExpand: { [weak scene] composer in
        router?.workspace?.openChat(id, composer: composer)
        if let main = UIApplication.shared.openSessions.first(where: { $0.configuration.name == "Main" }) {
          UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: main))
        }
        if let scene { UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) }
      })
    let window = UIWindow(windowScene: scene)
    window.tintColor = .systemBlue
    window.rootViewController = UIHostingController(rootView: page.environment(AppModel.shared).environment(\.session, account))
    self.window = window
    window.makeKeyAndVisible()
    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 260, y: 160, width: 440, height: 600)))
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    // 页面消失时 onClose 已经把最新草稿交过来；窗口关掉时交回主会话。
    window?.rootViewController = nil
    window = nil
    if let chatId, let composer { router?.workspace?.updateDraft(composer, for: chatId) }
  }
}
