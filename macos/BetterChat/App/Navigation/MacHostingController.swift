import SwiftUI
import UIKit

/// SwiftUI 的导航栏在 Catalyst 中固定为 Pad 行为；将其公开 navigationItem 交给外层原生导航栏。
@MainActor
protocol MacNavigationReporting: AnyObject {
  var navigationChanged: ((UINavigationController) -> Void)? { get set }
}

final class MacHostingController<Content: View>: UIHostingController<Content>, MacNavigationReporting {
  var navigationChanged: ((UINavigationController) -> Void)?
  private var projectionScheduled = false
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    projectNavigation(in: self)
    scheduleProjection()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    projectNavigation(in: self)
    scheduleProjection()
  }
  private func scheduleProjection() {
    guard !projectionScheduled else { return }
    projectionScheduled = true
    // SwiftUI 的工具栏属性可能晚于父控制器的布局回调提交；同一轮合并后再取最终状态。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      projectionScheduled = false
      projectNavigation(in: self)
    }
  }
  private func projectNavigation(in controller: UIViewController) {
    if let navigation = controller as? UINavigationController, let navigationChanged {
      if !navigation.isNavigationBarHidden { navigation.setNavigationBarHidden(true, animated: false) }
      navigationChanged(navigation)
      return
    }
    for child in controller.children { projectNavigation(in: child) }
  }
}
