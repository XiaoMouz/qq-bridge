import UIKit

/// 主窗口的分栏：侧栏 + 右栏（聊天 / 资料）+ 右侧检查器（会话资料）。
///
/// 2026-10-17 按 macOS 习惯重做窄窗口：以前窄于 760 点时换成 iPhone 式的单栏导航（列表 → 详情 → 返回），现在始终是分栏。
/// 2026-11-09 用户要求：收起侧栏不是让它消失，而是缩成一条窄栏（切换按钮、消息 / 群助手、会话头像 + 角标、底部搜索）。
/// 宽窗口里收起 / 展开由用户决定并跨启动记住；窄窗口自动用窄栏，⌃⌘S 临时展开，选了会话自动收回。
///
/// 2026-10-14 实机：Catalyst 让 UISplitViewController 按尺寸类自行折叠时，NSToolbar 计算出 NaN 宽度并崩溃；
/// 所以尺寸类固定为 regular（只写 traitOverrides、不读取：读取未设置的覆盖值会触发断言），收起 / 展开由这里按宽度决定。
@MainActor
final class MacAdaptiveSplitController: UIViewController {
  let sidebarRoot: UIViewController
  let detailRoot: UIViewController
  private let split = UISplitViewController(style: .doubleColumn)
  private let sidebarNavigation = UINavigationController()
  private let detailNavigation = UINavigationController()
  /// 右侧检查器栏（会话资料）。2026-10-17：SwiftUI 的 .inspector 在 Catalyst 里浮在聊天上面、盖住右侧气泡和输入框，
  /// 改用分栏控制器自己的 inspector 栏，聊天会让出宽度。
  private let inspectorNavigation = UINavigationController()
  private(set) var inspectorContent: UIViewController?
  /// 窄窗口：侧栏收起（需要时浮在聊天上面），检查器不显示。
  private(set) var isNarrow = false
  /// 宽窗口里用户选择的窄栏状态，跨启动记住。
  private var railByUser = UserDefaults.standard.bool(forKey: MacAdaptiveSplitController.railKey) {
    didSet { UserDefaults.standard.set(railByUser, forKey: Self.railKey) }
  }
  private static let railKey = "mac.sidebarRail"
  /// 窄窗口里临时展开的完整侧栏（选了会话自动收回）。
  private var expandedWhileNarrow = false
  /// 侧栏现在是窄栏。
  private(set) var isRail = false
  /// 窄栏 / 完整侧栏切换后通知协调器（换列表样式、搜索入口）。
  var railChanged: ((Bool) -> Void)?
  /// 出现在窗口中（首次与重新出现）时通知协调器登记命令、恢复上次会话。
  var appeared: (() -> Void)?

  init(sidebarRoot: UIViewController, detailRoot: UIViewController) {
    self.sidebarRoot = sidebarRoot
    self.detailRoot = detailRoot
    super.init(nibName: nil, bundle: nil)
    split.preferredDisplayMode = .oneBesideSecondary
    split.preferredSplitBehavior = .tile
    // 系统侧栏按钮会把侧栏整个藏起来；收起改为窄栏，按钮由侧栏自己提供（完整时在标题栏，窄栏时在栏内顶部）。
    split.displayModeButtonVisibility = .never
    split.traitOverrides.horizontalSizeClass = .regular
    split.primaryBackgroundStyle = .sidebar
    isRail = railByUser
    applyColumnWidth()
    for navigation in [sidebarNavigation, detailNavigation, inspectorNavigation] {
      navigation.navigationBar.preferredBehavioralStyle = .mac
    }
    sidebarNavigation.setViewControllers([sidebarRoot], animated: false)
    detailNavigation.setViewControllers([detailRoot], animated: false)
    split.setViewController(sidebarNavigation, for: .primary)
    split.setViewController(detailNavigation, for: .secondary)
    inspectorNavigation.setNavigationBarHidden(true, animated: false)
    split.minimumInspectorColumnWidth = 280
    split.preferredInspectorColumnWidth = 320
    split.maximumInspectorColumnWidth = 440
    split.setViewController(inspectorNavigation, for: .inspector)
    split.hide(.inspector)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var canBecomeFirstResponder: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(split)
    split.view.frame = view.bounds
    split.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(split.view)
    split.didMove(toParent: self)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    appeared?()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let narrow = view.bounds.width < MacMetrics.compactWidth
    guard narrow != isNarrow else { return }
    isNarrow = narrow
    expandedWhileNarrow = false
    if narrow {
      split.hide(.inspector)
    } else if inspectorContent != nil {
      split.show(.inspector)
    }
    updateRail()
  }

  // MARK: 侧栏

  /// ⌃⌘S、侧栏按钮：完整侧栏 ⇄ 窄栏。
  func toggleSidebar() {
    if isNarrow { expandedWhileNarrow.toggle() } else { railByUser.toggle() }
    updateRail()
  }

  /// 需要完整侧栏的操作（联系人分区）：窄栏时展开。
  func expandSidebar() {
    guard isRail else { return }
    if isNarrow { expandedWhileNarrow = true } else { railByUser = false }
    updateRail()
  }

  /// 打开了聊天 / 资料：窄窗口里临时展开的侧栏收回窄栏，宽窗口不动。
  func showDetail() {
    guard isNarrow, expandedWhileNarrow else { return }
    expandedWhileNarrow = false
    updateRail()
  }

  private func updateRail() {
    let rail = isNarrow ? !expandedWhileNarrow : railByUser
    guard rail != isRail else { return }
    isRail = rail
    applyColumnWidth()
    if view.window != nil, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseInOut) { self.split.view.layoutIfNeeded() }
    }
    railChanged?(rail)
  }

  /// 窄栏宽度固定（不能拖）；完整侧栏恢复可拖动的范围。先放宽再收紧，避免中途最小值大于最大值。
  private func applyColumnWidth() {
    if isRail {
      split.minimumPrimaryColumnWidth = MacMetrics.railWidth
      split.maximumPrimaryColumnWidth = MacMetrics.railWidth
      split.preferredPrimaryColumnWidth = MacMetrics.railWidth
    } else {
      split.maximumPrimaryColumnWidth = MacMetrics.sidebarMaximumWidth
      split.minimumPrimaryColumnWidth = MacMetrics.sidebarMinimumWidth
      split.preferredPrimaryColumnWidth = MacMetrics.sidebarPreferredWidth
    }
  }

  // MARK: 检查器

  var isInspectorShown: Bool { inspectorContent != nil }

  /// 换检查器里的内容（换会话时）；nil 收起。窄窗口里先记着，变宽再显示。
  func showInspector(_ content: UIViewController?) {
    inspectorContent = content
    if let content {
      if inspectorNavigation.viewControllers.first !== content {
        inspectorNavigation.setViewControllers([content], animated: false)
      }
      if !isNarrow { split.show(.inspector) }
    } else {
      split.hide(.inspector)
      inspectorNavigation.setViewControllers([], animated: false)
    }
  }

  /// 媒体全屏覆盖关闭后补一次布局（以前用于跨断点搬移，现在只需刷新）。
  func presentationDidDismiss() {
    view.setNeedsLayout()
  }
}
