import UIKit

/// 主窗口的分栏：侧栏 + 右栏（聊天 / 资料）+ 右侧检查器（会话资料）。
///
/// 2026-10-17 按 macOS 习惯重做窄窗口：以前窄于 760 点时换成 iPhone 式的单栏导航（列表 → 详情 → 返回），
/// 现在始终是分栏，窄窗口只把侧栏收起来；⌃⌘S 或工具栏的侧栏按钮让侧栏浮在聊天上面，选了会话自动收回。
/// 宽窗口里用户自己收起的侧栏，变窄再变宽时不擅自展开。
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
  /// 用户在宽窗口里自己收起了侧栏。
  private var sidebarHiddenByUser = false
  /// 出现在窗口中（首次与重新出现）时通知协调器登记命令、恢复上次会话。
  var appeared: (() -> Void)?

  init(sidebarRoot: UIViewController, detailRoot: UIViewController) {
    self.sidebarRoot = sidebarRoot
    self.detailRoot = detailRoot
    super.init(nibName: nil, bundle: nil)
    split.preferredDisplayMode = .oneBesideSecondary
    split.preferredSplitBehavior = .tile
    split.displayModeButtonVisibility = .always
    split.traitOverrides.horizontalSizeClass = .regular
    split.primaryBackgroundStyle = .sidebar
    split.minimumPrimaryColumnWidth = MacMetrics.sidebarMinimumWidth
    split.maximumPrimaryColumnWidth = MacMetrics.sidebarMaximumWidth
    split.preferredPrimaryColumnWidth = MacMetrics.sidebarPreferredWidth
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
    if narrow {
      split.preferredSplitBehavior = .overlay
      split.preferredDisplayMode = .secondaryOnly
      split.hide(.inspector)
    } else {
      split.preferredSplitBehavior = .tile
      split.preferredDisplayMode = sidebarHiddenByUser ? .secondaryOnly : .oneBesideSecondary
      if inspectorContent != nil { split.show(.inspector) }
    }
  }

  // MARK: 侧栏

  private var isSidebarShown: Bool { split.displayMode == .oneBesideSecondary || split.displayMode == .oneOverSecondary }

  /// 让侧栏可见（切换分区、⌘F）：窄窗口里浮在聊天上面。
  func showSidebar() {
    split.preferredDisplayMode = isNarrow ? .oneOverSecondary : .oneBesideSecondary
    if !isNarrow { sidebarHiddenByUser = false }
  }

  /// 打开了聊天 / 资料：窄窗口里收回浮着的侧栏，宽窗口不动。
  func showDetail() {
    if isNarrow { split.preferredDisplayMode = .secondaryOnly }
  }

  /// ⌃⌘S、工具栏侧栏按钮。
  func toggleSidebar() {
    if isSidebarShown {
      split.preferredDisplayMode = .secondaryOnly
      if !isNarrow { sidebarHiddenByUser = true }
    } else {
      showSidebar()
    }
  }

  /// ⌘F 在侧栏被收起时要先恢复侧栏，再聚焦搜索框。
  func revealSidebar() {
    if !isSidebarShown { showSidebar() }
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
