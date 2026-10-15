import UIKit

/// 右栏容器：保留各页导航栈，只对详情内容做短淡入；连续切换不会留下拦截点击的旧页。
/// 子页面（SwiftUI NavigationStack）的标题、按钮与返回动作投射到外层原生工具栏，只保留一行标题栏。
@MainActor
final class MacDetailContainer: UIViewController {
  private(set) var current: UIViewController?
  private var projectedItem: UINavigationItem?
  private var projectedDepth = 0
  private var projectedTitle: String?
  private var projectedSubtitle: String?
  private var projectedButtons: [UIBarButtonItem] = []
  private var projectedGroups: [UIBarButtonItemGroup] = []
  private var projectedEnabled: [Bool] = []

  private func project(_ navigation: UINavigationController) {
    guard let source = navigation.navigationBar.topItem else { return }
    let buttons = source.rightBarButtonItems ?? []
    let groups = source.leadingItemGroups + source.centerItemGroups + source.trailingItemGroups
    let depth = navigation.viewControllers.count
    let enabled = (buttons + groups.flatMap { $0.barButtonItems }).map { $0.isEnabled }
    let enabledChanged = projectedItem === source && projectedEnabled != enabled
    guard projectedItem !== source || projectedDepth != depth || projectedTitle != source.title || projectedSubtitle != source.subtitle || projectedButtons != buttons || projectedGroups != groups || enabledChanged else { return }
    projectedItem = source
    projectedDepth = depth
    projectedTitle = source.title
    projectedSubtitle = source.subtitle
    projectedButtons = buttons
    projectedGroups = groups
    projectedEnabled = enabled
    navigationItem.title = source.title
    navigationItem.subtitle = source.subtitle
    navigationItem.titleView = source.titleView
    navigationItem.style = .editor
    // 2026-10-15 实机：共享 UIBarButtonItem 已恢复 enabled，但 Catalyst 外层仍显示禁用。
    // 对原位属性变化重新挂载，使原生工具栏重新读取状态；不改变按钮动作或强制启用。
    if enabledChanged {
      navigationItem.rightBarButtonItems = []
      navigationItem.trailingItemGroups = []
      navigationItem.centerItemGroups = []
      navigationItem.leadingItemGroups = []
    }
    navigationItem.rightBarButtonItems = buttons
    navigationItem.trailingItemGroups = source.trailingItemGroups
    navigationItem.centerItemGroups = source.centerItemGroups
    navigationItem.leftBarButtonItems = source.leftBarButtonItems
    navigationItem.leadingItemGroups = source.leadingItemGroups
    if depth > 1 {
      navigationItem.backAction = UIAction(title: "返回", image: UIImage(systemName: MacSymbol.back)) { [weak navigation, weak self] _ in
        navigation?.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
        if let navigation { self?.project(navigation) }
      }
    } else {
      navigationItem.backAction = nil
    }
  }

  func show(_ controller: UIViewController) {
    guard current !== controller else { return }
    loadViewIfNeeded()
    let previous = current
    let snapshot = !UIAccessibility.isReduceMotionEnabled && view.window != nil
      ? previous?.view.snapshotView(afterScreenUpdates: false) : nil
    previous?.willMove(toParent: nil)
    previous?.view.removeFromSuperview()
    previous?.removeFromParent()
    current = controller
    projectedItem = nil
    navigationItem.title = nil
    navigationItem.subtitle = nil
    navigationItem.titleView = nil
    navigationItem.leftBarButtonItems = []
    navigationItem.rightBarButtonItems = []
    navigationItem.backAction = nil
    navigationItem.leadingItemGroups = []
    navigationItem.centerItemGroups = []
    navigationItem.trailingItemGroups = []
    (controller as? MacNavigationReporting)?.navigationChanged = { [weak self, weak controller] navigation in
      guard let self, self.current === controller else { return }
      self.project(navigation)
    }
    addChild(controller)
    controller.view.frame = view.bounds
    controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(controller.view)
    controller.didMove(toParent: self)
    if let snapshot {
      snapshot.frame = view.bounds
      snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      snapshot.isUserInteractionEnabled = false
      snapshot.accessibilityElementsHidden = true
      view.addSubview(snapshot)
      UIView.animate(withDuration: MacMetrics.transitionDuration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
        snapshot.alpha = 0
      } completion: { _ in snapshot.removeFromSuperview() }
    }
  }
}
