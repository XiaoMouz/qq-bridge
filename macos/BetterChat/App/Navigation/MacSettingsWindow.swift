import SwiftUI
import UIKit

/// 设置窗口（⌘,）：和 Mac 系统的设置窗口一样，独立窗口、顶部一排图标标签。
/// 2026-10-17 按 macOS 设计规范从主窗口侧栏的第三个分区挪出来：改设置不再离开当前聊天。
/// 页面仍由工作区的页面工厂创建（共用账号会话、手动同步），窗口只负责切换和标题。
@MainActor
enum MacSettingsWindow {
  static let activityType = "com.xiaomouz.betterchat.mac.settings"
  static let configurationName = "Settings"

  /// 已开着就拉到前面，没有就新开一个；同一时间只有一个设置窗口。
  static func open(_ setting: MacSetting? = nil) {
    if let session = UIApplication.shared.openSessions.first(where: { $0.configuration.name == configurationName }),
       let delegate = session.scene?.delegate as? MacSettingsSceneDelegate {
      if let setting { delegate.show(setting) }
      UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
      return
    }
    let activity = NSUserActivity(activityType: activityType)
    activity.targetContentIdentifier = "settings"
    if let setting { activity.userInfo = ["setting": setting.rawValue] }
    var request = UISceneSessionActivationRequest(role: .windowApplication)
    request.userActivity = activity
    UIApplication.shared.activateSceneSession(for: request) { _ in
      Task { @MainActor in AppModel.shared.showToast(AppToast(text: "无法打开设置窗口，请重试")) }
    }
  }

  /// 退出登录：页面依赖的账号会话失效，关掉设置窗口。
  static func close() {
    for session in UIApplication.shared.openSessions where session.configuration.name == configurationName {
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
  }
}

@MainActor
final class MacSettingsSceneDelegate: UIResponder, UIWindowSceneDelegate, NSToolbarDelegate {
  var window: UIWindow?
  private weak var scene: UIWindowScene?
  private let container = MacSettingsContainer()
  private var current: MacSetting = .account
  private var toolbar: NSToolbar?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    self.scene = scene
    // 设置窗口不随主窗口恢复：重启后由 ⌘, 重新打开，避免恢复出一个没有账号会话的空窗口。
    scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(format: "SELF == 'settings'")
    scene.sizeRestrictions?.minimumSize = CGSize(width: 560, height: 420)
    scene.sizeRestrictions?.allowsFullScreen = false
    let toolbar = NSToolbar(identifier: "com.xiaomouz.betterchat.mac.settings")
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    toolbar.allowsUserCustomization = false
    scene.titlebar?.toolbar = toolbar
    scene.titlebar?.toolbarStyle = .preference
    scene.titlebar?.titleVisibility = .visible
    self.toolbar = toolbar
    let window = UIWindow(windowScene: scene)
    window.tintColor = .systemBlue
    window.rootViewController = container
    self.window = window
    let requested = options.userActivities.first { $0.activityType == MacSettingsWindow.activityType }?
      .userInfo?["setting"] as? String
    show(requested.flatMap(MacSetting.init(rawValue:)) ?? .account)
    window.makeKeyAndVisible()
    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 200, y: 140, width: 680, height: 560)))
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    container.show(nil)
    window = nil
  }

  func show(_ setting: MacSetting) {
    current = setting
    toolbar?.selectedItemIdentifier = Self.identifier(setting)
    scene?.title = setting.rawValue
    container.show((UIApplication.shared.delegate as? MacAppDelegate)?.router.workspace?.settingsPage(setting))
  }

  // MARK: NSToolbarDelegate

  private static func identifier(_ setting: MacSetting) -> NSToolbarItem.Identifier { .init("settings.\(setting)") }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { MacSetting.allCases.map(Self.identifier) }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { MacSetting.allCases.map(Self.identifier) }
  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { MacSetting.allCases.map(Self.identifier) }

  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    guard let setting = MacSetting.allCases.first(where: { Self.identifier($0) == itemIdentifier }) else { return nil }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = setting.rawValue
    item.toolTip = setting.rawValue
    item.image = UIImage(systemName: setting.symbol)
    item.target = self
    item.action = #selector(selectItem(_:))
    return item
  }

  @objc private func selectItem(_ sender: NSToolbarItem) {
    guard let setting = MacSetting.allCases.first(where: { Self.identifier($0) == sender.itemIdentifier }) else { return }
    show(setting)
  }
}

/// 设置窗口的内容区：换页时整页替换；没有登录（没有工作区）时显示提示。
@MainActor
final class MacSettingsContainer: UIViewController {
  private var current: UIViewController?
  private lazy var signedOut = UIHostingController(rootView:
    ContentUnavailableView("登录后可以修改设置", systemImage: "person.crop.circle.badge.exclamationmark"))

  func show(_ page: UIViewController?) {
    loadViewIfNeeded()
    let next = page ?? signedOut
    guard current !== next else { return }
    current?.willMove(toParent: nil)
    current?.view.removeFromSuperview()
    current?.removeFromParent()
    current = next
    addChild(next)
    next.view.frame = view.bounds
    next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(next.view)
    next.didMove(toParent: self)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
  }
}
