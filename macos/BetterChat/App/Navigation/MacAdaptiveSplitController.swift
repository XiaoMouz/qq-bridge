import UIKit

/// 宽窗口使用双栏 UISplitViewController，窄窗口使用单个 UINavigationController（列表 → 详情）。
/// 两种布局搬移同一份 sidebarRoot / detailRoot，聊天、资料与设置页的状态都不重建。
///
/// 2026-10-14 实机：Catalyst 让 UISplitViewController 自行折叠两套 Mac 工具栏时，
/// NSToolbar 计算出 NaN 宽度并崩溃；因此断点由这里按宽度切换，不交给系统自动折叠。
/// 只写 traitOverrides.horizontalSizeClass、不读取：读取未设置的覆盖值会触发断言。
@MainActor
final class MacAdaptiveSplitController: UIViewController {
  let sidebarRoot: UIViewController
  let detailRoot: UIViewController
  private let split = UISplitViewController(style: .doubleColumn)
  private let sidebarNavigation = UINavigationController()
  private let detailNavigation = UINavigationController()
  private let compactNavigation = UINavigationController()
  private(set) var isCompact = false
  private var adapting = false
  /// 出现在窗口中（首次与重新出现）时通知协调器登记命令、恢复上次会话。
  var appeared: (() -> Void)?
  /// 由协调器回答：当前分区是否已有用户选过的详情（聊天、资料、设置页）。
  /// 切到窄布局时据此决定停在列表还是保留详情；宽布局下右栏总是“显示中”，不能作为依据。
  var hasDetail: (() -> Bool)?
  var layoutChanged: (() -> Void)?

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
    for navigation in [sidebarNavigation, detailNavigation, compactNavigation] {
      navigation.navigationBar.preferredBehavioralStyle = .mac
    }
    sidebarNavigation.setViewControllers([sidebarRoot], animated: false)
    detailNavigation.setViewControllers([detailRoot], animated: false)
    split.setViewController(sidebarNavigation, for: .primary)
    split.setViewController(detailNavigation, for: .secondary)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var canBecomeFirstResponder: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    install(split)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    appeared?()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let compact = view.bounds.width < MacMetrics.compactWidth
    // 2026-10-14 实机：全屏标注覆盖期间跨断点搬移导航栈，会让后台聊天抢回 Mac 工具栏。
    // 独立窗口中的表单不阻挡；透明媒体覆盖退出时由实际 onDismiss 请求补布局。
    guard !adapting, compact != isCompact, !hasFullScreenCover else { return }
    adapting = true
    isCompact = compact
    if compact {
      let showDetail = hasDetail?() ?? false
      remove(split)
      split.setViewController(nil, for: .primary)
      split.setViewController(nil, for: .secondary)
      sidebarNavigation.setViewControllers([], animated: false)
      detailNavigation.setViewControllers([], animated: false)
      compactNavigation.setViewControllers(showDetail ? [sidebarRoot, detailRoot] : [sidebarRoot], animated: false)
      install(compactNavigation)
    } else {
      remove(compactNavigation)
      compactNavigation.setViewControllers([], animated: false)
      sidebarNavigation.setViewControllers([sidebarRoot], animated: false)
      detailNavigation.setViewControllers([detailRoot], animated: false)
      split.setViewController(sidebarNavigation, for: .primary)
      split.setViewController(detailNavigation, for: .secondary)
      install(split)
    }
    adapting = false
    layoutChanged?()
  }

  private var hasFullScreenCover: Bool {
    guard let cover = presentedViewController, cover.viewIfLoaded?.window === view.window else { return false }
    return cover.modalPresentationStyle == .fullScreen || cover.modalPresentationStyle == .overFullScreen
  }

  func presentationDidDismiss() {
    view.setNeedsLayout()
  }

  /// 窄窗口里详情已压入导航栈。
  var isShowingCompactDetail: Bool { isCompact && compactNavigation.viewControllers.count > 1 }

  func showSidebar() {
    if isCompact {
      compactNavigation.popToRootViewController(animated: animated)
    } else {
      split.show(.primary)
    }
  }

  func showDetail() {
    if isCompact {
      guard compactNavigation.topViewController !== detailRoot else { return }
      compactNavigation.pushViewController(detailRoot, animated: animated)
    } else {
      split.show(.secondary)
    }
  }

  /// 宽窗口收起/恢复侧栏；窄窗口在列表与详情之间切换。
  func toggleSidebar() {
    if isCompact {
      if isShowingCompactDetail { showSidebar() }
      // 窄窗口没有并排的占位区；未选择联系人时，侧栏快捷键不能把用户带到空详情。
      else if hasDetail?() == true { showDetail() }
    } else if split.isShowing(.primary) {
      split.hide(.primary)
    } else {
      split.show(.primary)
    }
  }

  /// ⌘F 在侧栏被收起时要先恢复侧栏，再聚焦搜索框。
  func revealSidebar() {
    if isCompact { showSidebar() }
    else if !split.isShowing(.primary) { split.show(.primary) }
  }

  private var animated: Bool { !UIAccessibility.isReduceMotionEnabled && view.window != nil }

  private func install(_ controller: UIViewController) {
    addChild(controller)
    controller.view.frame = view.bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(controller.view)
    controller.didMove(toParent: self)
  }

  private func remove(_ controller: UIViewController) {
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
  }
}
