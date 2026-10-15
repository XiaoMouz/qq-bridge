import SwiftUI
import UIKit

/// 底部悬浮分区栏（系统 UITabBar）的实测占位高度，含外边距。由 MacSidebarView 用
/// onGeometryChange 在布局完成后写入，只用于设置 UIKit 列表的内容边距，不反过来影响栏本身的布局。
extension EnvironmentValues {
  @Entry var macFloatingBarInset: CGFloat = 0
}

/// 让 UIKit 列表铺到悬浮栏下面（Liquid Glass 后可见滚动内容），同时用底部内容边距保证最后一行能完整滚出。
///
/// 2026-10-14（JOINT_UI_REVIEW F5）：SwiftUI `safeAreaInset` 产生的是 SwiftUI 安全区，嵌入的 UIKit
/// 列表不会自动得到对应的 UIKit 安全区；靠系统自动调整无法确定是否会重复或漏加，因此关闭自动调整、
/// 显式设置内容边距与滚动条边距。列表顶部紧贴搜索框，原本就不需要系统的顶部调整。
@MainActor
protocol MacFloatingBarInsetting: AnyObject {
  func applyFloatingBarInset(_ inset: CGFloat)
}

extension MacFloatingBarInsetting where Self: UICollectionViewController {
  func applyFloatingBarInset(_ inset: CGFloat) {
    loadViewIfNeeded()
    guard let collectionView else { return }
    if collectionView.contentInsetAdjustmentBehavior != .never {
      collectionView.contentInsetAdjustmentBehavior = .never
    }
    guard collectionView.contentInset.bottom != inset else { return }
    collectionView.contentInset.bottom = inset
    collectionView.verticalScrollIndicatorInsets.bottom = inset
  }
}

extension MacDialogsController: MacFloatingBarInsetting {}
extension MacSearchResultsController: MacFloatingBarInsetting {}
