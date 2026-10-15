import QQBridgeKit
import SwiftUI
import UIKit

/// 会话列表：UIKit 差量渲染、原生选中与右键菜单；状态与操作都在 MacDialogsViewModel。
/// 列表只上报意图（打开、快速回复、进入群助手），由协调器决定右栏显示什么。
@MainActor
final class MacDialogsController: UICollectionViewController {
  private enum Row: Hashable { case chat(Int64), archive }
  private let session: Session
  private let model: AppModel
  private let viewModel: MacDialogsViewModel
  var openChat: ((DialogItem) -> Void)?
  var quickReply: ((Int64) -> Void)?
  var syncCompleted: (() -> Void)?
  private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
  private var appliedItems: [Int64: DialogItem] = [:]
  private var appliedArchived: [DialogItem] = []
  private struct ScrollPosition {
    let row: Row
    let offset: CGFloat
  }
  private var scrollPositions: [Bool: ScrollPosition] = [:]
  private var appliedRows: [Row] = []
  private var appliedPage: Bool?
  private var restorePagePosition = false
  private var pageAnimator: UIViewPropertyAnimator?
  private var transitionSnapshot: UIView?
  /// 正在显示的失败弹窗对应的身份；关闭动画结束前一直占用，避免观察变化时重复呈现。
  private var presentedFailureID: MacDialogsFailure.ID?

  var showsArchived: Bool { viewModel.showsArchived }

  init(session: Session, model: AppModel, viewModel: MacDialogsViewModel) {
    self.session = session
    self.model = model
    self.viewModel = viewModel
    var config = UICollectionLayoutListConfiguration(appearance: .sidebar)
    config.showsSeparators = false
    super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.backgroundColor = .clear
    collectionView.accessibilityLabel = "会话"
    let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
      guard let self else { return }
      if row == .archive {
        let groups = viewModel.archived
        cell.contentConfiguration = UIHostingConfiguration {
          ArchiveRow(items: groups, style: MacMetrics.dialogRow)
        }.margins(.horizontal, MacMetrics.rowHorizontalMargin).margins(.vertical, MacMetrics.rowVerticalMargin)
        cell.accessories = [.disclosureIndicator()]
        cell.accessibilityLabel = "群助手，\(groups.count) 个群，\(groups.filter { $0.dialog.unreadCount > 0 }.count) 个群有未读消息"
        return
      }
      guard case .chat(let id) = row, let item = viewModel.byID[id] else { return }
      cell.accessories = []
      let model = model, session = session
      cell.contentConfiguration = UIHostingConfiguration {
        MacDialogRow(item: item)
          .environment(model)
          .environment(\.session, session)
      }.margins(.horizontal, MacMetrics.rowHorizontalMargin).margins(.vertical, MacMetrics.rowVerticalMargin)
      cell.accessibilityLabel = "\(item.title)，\(Format.preview(item.dialog.topMessage))，\(item.dialog.unreadCount) 条未读"
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, index, id in
      collection.dequeueConfiguredReusableCell(using: registration, for: index, item: id)
    }
    observeState()
    viewModel.start { [weak model] items in model?.updateBadge(items) }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 窄窗口里列表被聊天页盖住时失败会先排队，回到列表再显示。
    presentNextFailure()
  }

  private func observeState() {
    // 观察闭包只读取模型；UIKit 更新放在外面，避免额外的 trait 观察进入依赖收集。
    _ = withObservationTracking {
      (viewModel.items, viewModel.failures.first?.id, viewModel.showsArchived)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeState() }
    }
    apply()
    presentNextFailure()
  }

  // MARK: 失败提示

  /// 一次只显示队首一条；不在窗口里、已有其他呈现或正在退场时等下一次机会（出现、关闭完成、状态变化）。
  private func presentNextFailure() {
    guard presentedFailureID == nil, let failure = viewModel.failures.first,
          viewIfLoaded?.window != nil, presentedViewController == nil,
          !isBeingDismissed, !isMovingFromParent else { return }
    let alert = UIAlertController(title: failure.title, message: failure.message, preferredStyle: .alert)
    switch failure.kind {
    case .observation:
      alert.addAction(UIAlertAction(title: "稍后", style: .cancel) { [weak self, weak alert] _ in
        self?.finishFailure(failure.id, retry: false, alert: alert)
      })
      let retry = UIAlertAction(title: "重试", style: .default) { [weak self, weak alert] _ in
        self?.finishFailure(failure.id, retry: true, alert: alert)
      }
      alert.addAction(retry)
      alert.preferredAction = retry
    case .operation:
      alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self, weak alert] _ in
        self?.finishFailure(failure.id, retry: false, alert: alert)
      })
    }
    presentedFailureID = failure.id
    present(alert, animated: true)
    // 呈现被 UIKit 拒绝（例如同时有别的转场）时不占位，留给下一次机会。
    if alert.presentingViewController == nil { presentedFailureID = nil }
  }

  private func finishFailure(_ id: MacDialogsFailure.ID, retry: Bool, alert: UIAlertController?) {
    guard presentedFailureID == id else { return }
    // 先按已呈现的身份确认，再重试：重试只清观察失败，不会动排在后面的写操作失败。
    viewModel.acknowledge(id)
    if retry { viewModel.retryObservation() }
    // 按钮回调与关闭动画的先后不凭推测（L6）：仍在退场就等转场结束，否则直接显示下一条。
    if let alert, alert.presentingViewController != nil, let coordinator = alert.transitionCoordinator {
      coordinator.animate(alongsideTransition: nil) { [weak self] _ in
        MainActor.assumeIsolated { self?.failureDismissed(id) }
      }
    } else {
      failureDismissed(id)
    }
  }
  private func failureDismissed(_ id: MacDialogsFailure.ID) {
    guard presentedFailureID == id else { return }
    presentedFailureID = nil
    presentNextFailure()
  }

  // MARK: 协调器调用

  func selectChat(_ id: Int64) {
    viewModel.select(id)
    if let item = viewModel.byID[id], item.isArchived != viewModel.showsArchived {
      setArchived(item.isArchived)
    }
    if let path = dataSource?.indexPath(for: .chat(id)) {
      collectionView.selectItem(at: path, animated: false, scrollPosition: .centeredVertically)
    }
  }
  func setArchived(_ archived: Bool) {
    guard viewModel.showsArchived != archived else { return }
    finishPageTransition()
    if let top = collectionView.indexPathsForVisibleItems
      .compactMap({ path -> (Row, UICollectionViewLayoutAttributes)? in
        guard let row = dataSource.itemIdentifier(for: path),
              let attributes = collectionView.layoutAttributesForItem(at: path) else { return nil }
        return (row, attributes)
      }).min(by: { $0.1.frame.minY < $1.1.frame.minY }) {
      // 自适应行高会重估整页高度，保存像素距离会在返回时漂移；以最上方会话和行内偏移恢复。
      scrollPositions[viewModel.showsArchived] = ScrollPosition(row: top.0, offset: top.1.frame.minY - collectionView.contentOffset.y)
    }
    let animate = view.window != nil && !UIAccessibility.isReduceMotionEnabled
    let snapshot = animate ? collectionView.snapshotView(afterScreenUpdates: false) : nil
    let frame = collectionView.frame
    viewModel.setArchived(archived)
    restorePagePosition = true
    apply()
    collectionView.layoutIfNeeded()
    guard let snapshot, let container = collectionView.superview else { return }
    // 用户导航独立于实时列表差量更新：旧页面快照滑出、新页面滑入，消息重排仍不做搬行动画。
    snapshot.frame = frame
    snapshot.isUserInteractionEnabled = false
    snapshot.accessibilityElementsHidden = true
    container.addSubview(snapshot)
    transitionSnapshot = snapshot
    let direction: CGFloat = archived ? 1 : -1
    let distance = collectionView.bounds.width
    collectionView.transform = CGAffineTransform(translationX: direction * distance, y: 0)
    let animator = UIViewPropertyAnimator(duration: 0.24, curve: .easeInOut) { [weak self] in
      self?.collectionView.transform = .identity
      snapshot.transform = CGAffineTransform(translationX: -direction * distance, y: 0)
      snapshot.alpha = 0
    }
    animator.addCompletion { [weak self] _ in
      snapshot.removeFromSuperview()
      self?.transitionSnapshot = nil
      self?.pageAnimator = nil
    }
    pageAnimator = animator
    animator.startAnimation()
  }

  private func finishPageTransition() {
    pageAnimator?.stopAnimation(true)
    pageAnimator = nil
    transitionSnapshot?.removeFromSuperview()
    transitionSnapshot = nil
    collectionView.transform = .identity
  }

  private func restoreScrollPosition() {
    collectionView.layoutIfNeeded()
    guard let position = scrollPositions[viewModel.showsArchived],
          let path = dataSource.indexPath(for: position.row) else {
      collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
      return
    }
    collectionView.scrollToItem(at: path, at: .top, animated: false)
    collectionView.layoutIfNeeded()
    if let attributes = collectionView.layoutAttributesForItem(at: path) {
      let minimum = -collectionView.adjustedContentInset.top
      collectionView.setContentOffset(CGPoint(x: 0, y: max(minimum, attributes.frame.minY - position.offset)), animated: false)
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    finishPageTransition()
    super.viewWillDisappear(animated)
  }
  func refreshDialogs() {
    viewModel.refresh { [weak self] in self?.syncCompleted?() }
  }
  /// 再点“消息”标签：只滚动到下一个计入角标的未读会话，不打开、不标已读。
  func scrollToNextUnread() {
    let ids = dataSource.snapshot().itemIdentifiers.compactMap { row -> Int64? in
      if case .chat(let id) = row { return id }
      return nil
    }
    guard let next = viewModel.nextUnreadToScroll(orderedIDs: ids),
          let path = dataSource.indexPath(for: .chat(next)) else { return }
    collectionView.scrollToItem(at: path, at: .top, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  // MARK: 渲染

  private func apply() {
    guard dataSource != nil else { return }
    let visible = viewModel.visible
    var rows = visible.map { Row.chat($0.id) }
    let archived = viewModel.archived
    if !viewModel.showsArchived, !archived.isEmpty {
      // 与 iOS 一致：汇总行按最新消息时间插入普通会话，置顶会话始终在前。
      let archiveTime = archived.map(\.dialog.topTime).max() ?? 0
      let index = visible.firstIndex { !$0.dialog.pinned && $0.dialog.topTime < archiveTime } ?? rows.endIndex
      rows.insert(.archive, at: index)
    }
    // 直接导航已经提交快照，Observation 随后的相同通知无需再做一次自适应布局。
    guard rows != appliedRows || appliedItems != viewModel.byID || appliedArchived != archived || appliedPage != viewModel.showsArchived else { return }
    appliedRows = rows
    appliedPage = viewModel.showsArchived
    var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
    snapshot.appendSections([0]); snapshot.appendItems(rows)
    let previous = Set(dataSource.snapshot().itemIdentifiers)
    snapshot.reconfigureItems(visible.filter { previous.contains(.chat($0.id)) && appliedItems[$0.id] != $0 }.map { .chat($0.id) })
    if rows.contains(.archive), previous.contains(.archive), archived != appliedArchived { snapshot.reconfigureItems([.archive]) }
    appliedItems = viewModel.byID
    appliedArchived = archived
    // 2026-10-14 实机截图：多个群连续来消息时，搬行动画叠加会留下重叠文字和空洞。
    // 数据刷新仍走差量重配，只取消自动排序的搬移动画；用户切分区、返回页面的动画另行保留。
    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      guard let self else { return }
      if let id = viewModel.selectedID, let path = dataSource.indexPath(for: .chat(id)) {
        collectionView.selectItem(at: path, animated: false, scrollPosition: [])
      }
      if restorePagePosition {
        restorePagePosition = false
        restoreScrollPosition()
      }
    }
    if rows.isEmpty {
      var empty = UIContentUnavailableConfiguration.empty()
      empty.image = UIImage(systemName: MacSymbol.emptyChat)
      empty.text = viewModel.showsArchived ? "群助手里没有群" : "暂无会话"
      contentUnavailableConfiguration = empty
    } else { contentUnavailableConfiguration = nil }
  }

  override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
    if row == .archive { setArchived(true); return }
    guard case .chat(let id) = row, let item = viewModel.byID[id] else { return }
    viewModel.select(id)
    openChat?(item)
  }

  override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    guard case .chat(let id) = dataSource.itemIdentifier(for: indexPath), let item = viewModel.byID[id] else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return nil }
      var actions = [
        UIAction(title: "快速回复", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in self?.quickReply?(id) },
        UIAction(title: item.dialog.pinned ? "取消置顶" : "置顶", image: UIImage(systemName: item.dialog.pinned ? "pin.slash" : "pin")) { [weak self] _ in self?.viewModel.togglePinned(item) },
        UIAction(title: item.isMuted ? "接收并提醒" : "免打扰", image: UIImage(systemName: item.isMuted ? "bell" : "bell.slash")) { [weak self] _ in self?.viewModel.toggleMuted(item) },
      ]
      if item.dialog.unreadCount > 0 {
        actions.insert(UIAction(title: "标为已读", image: UIImage(systemName: "checkmark.message")) { [weak self] _ in
          self?.viewModel.markRead(item)
        }, at: 2)
      }
      if item.isGroup {
        actions.append(UIAction(title: item.isArchived ? "移出群助手" : "收进群助手", image: UIImage(systemName: MacSymbol.archive)) { [weak self] _ in self?.viewModel.toggleArchived(item) })
      }
      return UIMenu(children: actions)
    }
  }
}

private struct MacDialogRow: View {
  let item: DialogItem
  @Environment(AppModel.self) private var model
  var body: some View { DialogRow(item: item, typing: model.isTyping(item.id), style: MacMetrics.dialogRow) }
}
