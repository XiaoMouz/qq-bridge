import UIKit

/// 侧栏里的 UIKit 列表（会话、搜索结果）：关闭系统的内容边距自动调整，底部留一点空，最后一行不贴窗口边。
///
/// 2026-10-14（JOINT_UI_REVIEW F5）：SwiftUI 布局给嵌入的 UIKit 列表的安全区不可靠，自动调整可能重复或漏加，
/// 所以显式设置。2026-10-17 底部分区栏去掉后，只剩这一点底部留白。
@MainActor
protocol MacSidebarListInsetting: AnyObject {
  func applySidebarListInsets()
}

extension MacSidebarListInsetting where Self: UICollectionViewController {
  func applySidebarListInsets() {
    loadViewIfNeeded()
    guard let collectionView else { return }
    if collectionView.contentInsetAdjustmentBehavior != .never {
      collectionView.contentInsetAdjustmentBehavior = .never
    }
    let bottom = MacMetrics.sidebarInset
    guard collectionView.contentInset.bottom != bottom else { return }
    collectionView.contentInset.bottom = bottom
    collectionView.verticalScrollIndicatorInsets.bottom = bottom
  }
}

extension MacDialogsController: MacSidebarListInsetting {}
extension MacSearchResultsController: MacSidebarListInsetting {}
