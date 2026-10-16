import UIKit

/// 菜单栏：“对话”菜单与“显示 → 页面”。菜单动作显式路由到工作区；快捷键放在窗口上，
/// 跨 UIKit / SwiftUI 边界仍可用（见 MacWindow）。
@MainActor
struct MacMenuBuilder {
  let router: MacCommandRouter

  func build(with builder: any UIMenuBuilder) {
    // 只增加媒体场景；主工作区仍由唯一协调器管理，不提供重复主工作区的入口。
    builder.remove(menu: .newItem)
    let attributes: UIMenuElement.Attributes = router.workspace == nil ? .disabled : []
    let router = router
    builder.insertSibling(UIMenu(title: "对话", identifier: .init("com.xiaomouz.betterchat.mac.conversations"), children: [
      UIAction(title: "搜索…", image: UIImage(systemName: MacSymbol.search), attributes: attributes) { _ in router.workspace?.focusSidebarSearch() },
      UIAction(title: "下一个未读会话", attributes: attributes) { _ in router.workspace?.nextUnread() },
      UIKeyCommand(title: "显示/隐藏会话资料", image: UIImage(systemName: "info.circle"), action: #selector(MacWindow.toggleChatInfo(_:)),
                   input: "i", modifierFlags: [.command, .alternate]),
    ]), afterMenu: .file)
    builder.insertChild(UIMenu(title: "页面", options: .displayInline, children: [
      UIAction(title: "显示/隐藏侧栏", image: UIImage(systemName: MacSymbol.sidebar), attributes: attributes) { _ in router.workspace?.toggleSidebar() },
    ] + MacSidebarSection.allCases.map { section in
      UIAction(title: section.title, image: UIImage(systemName: section.symbol), attributes: attributes) { _ in
        switch section {
        case .messages: router.workspace?.showMessages()
        case .contacts: router.workspace?.showContacts()
        }
      }
    }), atStartOfMenu: .view)
    #if DEBUG
    // 固定尺寸入口用于实机重复检查分栏断点，不进入发布构建。
    let layouts = [(640, 480), (720, 640), (1024, 640), (1280, 800)]
    builder.insertChild(UIMenu(title: "布局检查", children: layouts.map { width, height in
      UIAction(title: "窗口 \(width) × \(height)", attributes: attributes) { _ in
        router.workspace?.requestWindowSize(width: CGFloat(width), height: CGFloat(height))
      }
    }), atEndOfMenu: .window)
    // 只覆盖本 App 的窗口，用于深浅色截图；不改用户的系统外观，也不持久化。
    let appearances: [(String, UIUserInterfaceStyle)] = [("跟随系统", .unspecified), ("浅色", .light), ("深色", .dark)]
    builder.insertChild(UIMenu(title: "外观检查", children: appearances.map { title, style in
      UIAction(title: title) { _ in
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
          for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
      }
    }), atEndOfMenu: .window)
    #endif
    builder.insertSibling(UIMenu(title: "", identifier: .init("com.xiaomouz.betterchat.mac.settings"), options: .displayInline, children: [
      UIAction(title: "设置…") { _ in MacSettingsWindow.open() },
    ]), afterMenu: .about)
    // 自动更新（Sparkle）：只在配了更新源的发布构建里出现。
    if MacUpdater.isAvailable {
      builder.insertSibling(UIMenu(title: "", identifier: .init("com.xiaomouz.betterchat.mac.updates"), options: .displayInline, children: [
        UIAction(title: "检查更新…") { _ in MacUpdater.checkForUpdates() },
      ]), afterMenu: .about)
    }
  }
}

/// 窗口保持在响应链中，分区内的 SwiftUI 页面也能使用应用快捷键。
@MainActor
final class MacWindow: UIWindow {
  private let router: MacCommandRouter

  init(windowScene: UIWindowScene, router: MacCommandRouter) {
    self.router = router
    super.init(windowScene: windowScene)
    // 回应面板、资料卡在鼠标位置弹出（见 MacPopover.swift）。
    MacPointer.install(on: self)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var keyCommands: [UIKeyCommand]? {
    [
      UIKeyCommand(title: "搜索侧栏…", action: #selector(searchSidebar(_:)), input: "f", modifierFlags: .command, discoverabilityTitle: "搜索侧栏…"),
      UIKeyCommand(title: "下一个未读会话", action: #selector(openNextUnread(_:)), input: "u", modifierFlags: [.command, .shift], discoverabilityTitle: "下一个未读会话"),
      UIKeyCommand(title: "消息", action: #selector(showMessages(_:)), input: "1", modifierFlags: .command),
      UIKeyCommand(title: "联系人", action: #selector(showContacts(_:)), input: "2", modifierFlags: .command),
      UIKeyCommand(title: "显示/隐藏侧栏", action: #selector(toggleWorkspaceSidebar(_:)), input: "s", modifierFlags: [.control, .command]),
      UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(returnToMessages(_:))),
      UIKeyCommand(title: "设置…", action: #selector(openSettings(_:)), input: ",", modifierFlags: .command, discoverabilityTitle: "设置…"),
    ]
  }
  @objc func searchSidebar(_ sender: UICommand) { router.workspace?.focusSidebarSearch() }
  @objc func showContacts(_ sender: UICommand) { router.workspace?.showContacts() }
  @objc func toggleWorkspaceSidebar(_ sender: UICommand) { router.workspace?.toggleSidebar() }
  @objc func openSettings(_ sender: UICommand) { MacSettingsWindow.open() }
  @objc func openNextUnread(_ sender: UICommand) { router.workspace?.nextUnread() }
  @objc func showMessages(_ sender: UICommand) { router.workspace?.showMessages() }
  @objc func returnToMessages(_ sender: UICommand) { router.workspace?.cancelSidebarNavigation() }
  @objc func toggleChatInfo(_ sender: UICommand) { router.workspace?.toggleChatInfo() }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(returnToMessages) {
      return router.isAvailable && router.workspace?.canReturnToMessages == true
    }
    if action == #selector(openSettings) { return true }
    if [#selector(searchSidebar), #selector(openNextUnread), #selector(toggleChatInfo), #selector(showMessages), #selector(showContacts), #selector(toggleWorkspaceSidebar)].contains(action) {
      return router.isAvailable
    }
    return super.canPerformAction(action, withSender: sender)
  }
}
