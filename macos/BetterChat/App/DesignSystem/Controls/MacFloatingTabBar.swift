import SwiftUI
import UIKit

/// 侧栏底部的悬浮分区栏。使用真实 UITabBar：系统负责 Liquid Glass 外观、选中动画、
/// 符号布局、命中区域和“标签”辅助功能语义；这里只描述条目。
struct MacFloatingTabBar: UIViewRepresentable {
  struct Item: Equatable {
    let title: String
    let symbol: String
    let selectedSymbol: String
    let identifier: String
    var badge: Int = 0
  }
  let items: [Item]
  let selectedIndex: Int
  let select: (Int) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(select: select) }
  func makeUIView(context: Context) -> UITabBar {
    let bar = UITabBar()
    bar.delegate = context.coordinator
    bar.itemPositioning = .fill
    // 2026-10-14 实机：窄窗口侧栏不在分栏控制器内，继承到 regular 尺寸类后 UITabBar 改成
    // 图标在左、文字在右的横排，未读角标压住文字；宽窗口则是竖排。固定为 compact 让两种
    // 宽度都使用系统竖排布局（角标落在图标右上角）。只写覆盖值，不读取（读未设置的值会断言）。
    bar.traitOverrides.horizontalSizeClass = .compact
    return bar
  }
  func updateUIView(_ bar: UITabBar, context: Context) {
    context.coordinator.select = select
    if context.coordinator.items != items {
      let rebuild = context.coordinator.items.map { $0.count != items.count || zip($0, items).contains { $0.title != $1.title || $0.symbol != $1.symbol } } ?? true
      context.coordinator.items = items
      if rebuild {
        bar.items = items.enumerated().map { index, item in
          // 选中与未选中使用同一组符号配置，系统只换填充样式，不改变字重和比例。
          let tab = UITabBarItem(title: item.title,
                                 image: UIImage(systemName: item.symbol, withConfiguration: MacMetrics.tabSymbolConfiguration),
                                 selectedImage: UIImage(systemName: item.selectedSymbol, withConfiguration: MacMetrics.tabSymbolConfiguration))
          tab.tag = index
          tab.accessibilityIdentifier = item.identifier
          return tab
        }
      }
      for (tab, item) in zip(bar.items ?? [], items) {
        tab.badgeValue = item.badge > 0 ? (item.badge > 99 ? "99+" : String(item.badge)) : nil
        tab.accessibilityValue = item.badge > 0 ? "\(item.badge) 条未读" : nil
      }
    }
    let selected = bar.items?.indices.contains(selectedIndex) == true ? bar.items?[selectedIndex] : nil
    if bar.selectedItem !== selected { bar.selectedItem = selected }
  }
  /// 高度交给 UITabBar 自己计算：此前写死 52 点，选中态的图标在 macOS 27 上被裁切（JOINT_UI_REVIEW F2）。
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITabBar, context: Context) -> CGSize? {
    let width = proposal.width ?? MacMetrics.sidebarPreferredWidth
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
    return CGSize(width: width, height: fitted.height)
  }
  @MainActor final class Coordinator: NSObject, UITabBarDelegate {
    var select: (Int) -> Void
    var items: [Item]?
    init(select: @escaping (Int) -> Void) { self.select = select }
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) { select(item.tag) }
  }
}
