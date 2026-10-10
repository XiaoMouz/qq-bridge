// 消息列表（docs/design.md 6.1）：UICollectionView + 可比较数据源，单元格用 UIHostingConfiguration 渲染 SwiftUI 气泡。
// - 打开时停在最底部；新消息到达时，如果本来就在底部附近就跟着滚到底；
// - 往上翻页插入更早的消息时保持当前看到的位置不跳；
// - 滑到离顶部不远时通知外面加载更早的消息。
import QQBridgeKit
import SwiftUI
import UIKit

struct ChatCollectionView: UIViewControllerRepresentable {
  let items: [ChatItem]
  let context: MessageContext
  let onReachTop: () -> Void

  func makeUIViewController(context _: Context) -> ChatCollectionController {
    ChatCollectionController()
  }

  func updateUIViewController(_ controller: ChatCollectionController, context _: Context) {
    controller.messageContext = context
    controller.onReachTop = onReachTop
    controller.apply(items)
  }
}

@MainActor
final class ChatCollectionController: UIViewController, UICollectionViewDelegate {
  var messageContext: MessageContext?
  var onReachTop: (() -> Void)?

  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
  private var byId: [String: ChatItem] = [:]
  private var firstLoad = true
  /// 贴底：打开会话后、用户自己往上滑之前，内容高度变了（图片加载完撑开单元格）也保持在最底部。
  private var stickToBottom = true
  private var contentSizeObservation: NSKeyValueObservation?

  override func viewDidLoad() {
    super.viewDidLoad()
    var config = UICollectionLayoutListConfiguration(appearance: .plain)
    config.showsSeparators = false
    config.backgroundColor = .clear
    let layout = UICollectionViewCompositionalLayout.list(using: config)
    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.backgroundColor = .systemBackground
    collectionView.keyboardDismissMode = .interactive
    collectionView.delegate = self
    collectionView.selfSizingInvalidation = .enabledIncludingConstraints
    view.addSubview(collectionView)
    contentSizeObservation = collectionView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
      guard change.oldValue != change.newValue else { return }
      MainActor.assumeIsolated {
        guard let self, self.stickToBottom, !self.collectionView.isTracking else { return }
        self.scrollToBottom(animated: false)
      }
    }

    let cell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
      guard let self, let item = self.byId[id], let context = self.messageContext else { return }
      cell.contentConfiguration = UIHostingConfiguration {
        MessageRow(item: item, context: context, previous: self.previous(of: id))
      }
      .margins(.horizontal, 12)
      .margins(.vertical, 2)
      cell.backgroundConfiguration = .clear()
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, id in
      cv.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
    }
  }

  func apply(_ items: [ChatItem]) {
    let oldIds = dataSource.snapshot().itemIdentifiers
    let changed = items.filter { byId[$0.id] != $0 }.map(\.id)
    byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    let ids = items.map(\.id)

    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(ids)
    let stillThere = Set(ids)
    snapshot.reconfigureItems(changed.filter { stillThere.contains($0) && oldIds.contains($0) })

    let prepended = !oldIds.isEmpty && ids.first != oldIds.first && ids.contains(oldIds.first!)
    let nearBottom = isNearBottom
    let offsetFromBottom = collectionView.contentSize.height - collectionView.contentOffset.y

    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      guard let self else { return }
      self.collectionView.layoutIfNeeded()
      if self.firstLoad, !ids.isEmpty {
        self.firstLoad = false
        self.scrollToBottom(animated: false)
      } else if prepended {
        // 在顶部插入了更早的消息：保持离底部的距离不变，看到的内容就不会跳。
        self.collectionView.contentOffset.y = self.collectionView.contentSize.height - offsetFromBottom
      } else if (nearBottom || self.stickToBottom), ids.last != oldIds.last {
        self.scrollToBottom(animated: !self.stickToBottom)
      }
    }
  }

  private var isNearBottom: Bool {
    let cv = collectionView!
    return cv.contentOffset.y + cv.bounds.height - cv.adjustedContentInset.bottom > cv.contentSize.height - 120
  }

  private func scrollToBottom(animated: Bool) {
    let cv = collectionView!
    let bottom = max(-cv.adjustedContentInset.top, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
    cv.setContentOffset(CGPoint(x: 0, y: bottom), animated: animated)
  }

  private func previous(of id: String) -> ChatItem? {
    let ids = dataSource.snapshot().itemIdentifiers
    guard let i = ids.firstIndex(of: id), i > 0 else { return nil }
    return byId[ids[i - 1]]
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    if !firstLoad, scrollView.isTracking || scrollView.isDecelerating, scrollView.contentOffset.y < 400 { onReachTop?() }
  }

  func scrollViewWillBeginDragging(_: UIScrollView) {
    stickToBottom = false
  }

  func scrollViewDidEndDecelerating(_: UIScrollView) {
    stickToBottom = isNearBottom
  }

  func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { stickToBottom = isNearBottom }
  }

  func collectionView(_: UICollectionView, shouldSelectItemAt _: IndexPath) -> Bool { false }
}
