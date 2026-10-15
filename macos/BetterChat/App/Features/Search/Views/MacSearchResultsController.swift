import QQBridgeKit
import SwiftUI
import UIKit

/// 搜索结果与会话列表一样由 UIKit 管理行焦点，避免 SwiftUI 的 List 焦点落到右侧聊天。
/// Tab 从搜索框进入，上下键选择并打开右侧内容，Return 重新定位当前结果，Shift-Tab 回到搜索框。
@MainActor
final class MacSearchResultsController: UICollectionViewController {
  typealias ResultID = MacSidebarSearchViewModel.ResultID
  typealias Result = MacSidebarSearchViewModel.Result
  typealias Group = MacSidebarSearchViewModel.Group

  private let session: Session
  private var dataSource: UICollectionViewDiffableDataSource<String, ResultID>!
  private var results: [ResultID: Result] = [:]
  private var selected: ResultID?
  private var focusRequest: UUID
  var select: ((ResultID?) -> Void)?
  var returnToSearch: (() -> Void)?
  var rowAppeared: ((ResultID) -> Void)?

  init(session: Session, focusRequest: UUID) {
    self.session = session
    self.focusRequest = focusRequest
    var configuration = UICollectionLayoutListConfiguration(appearance: .sidebar)
    configuration.showsSeparators = false
    configuration.headerMode = .supplementary
    super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.backgroundColor = .clear
    collectionView.allowsFocus = true
    collectionView.selectionFollowsFocus = true
    collectionView.remembersLastFocusedIndexPath = true
    let cells = UICollectionView.CellRegistration<UICollectionViewListCell, ResultID> { [weak self] cell, _, id in
      guard let self, let result = results[id] else { return }
      let session = session
      let appeared = rowAppeared
      // 选中状态变化时系统只回调这一行的更新处理，按 isSelected 切换副标题 / 时间的前景层级；
      // 内容变化仍由快照只重配变化的行。
      cell.configurationUpdateHandler = { cell, state in
        cell.contentConfiguration = UIHostingConfiguration {
          MacSidebarRow(title: result.title, subtitle: result.subtitle, trailing: result.trailing,
                        avatar: result.avatar, busy: result.busy,
                        subtitleLines: result.subtitleLines, emphasized: state.isSelected)
            .environment(\.session, session)
            .onAppear { appeared?(id) }
        }.margins(.horizontal, MacMetrics.rowHorizontalMargin).margins(.vertical, MacMetrics.rowVerticalMargin)
      }
      cell.setNeedsUpdateConfiguration()
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collection, path, id in
      collection.dequeueConfiguredReusableCell(using: cells, for: path, item: id)
    }
    let headers = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, path in
      guard let self, path.section < dataSource.snapshot().sectionIdentifiers.count else { return }
      var content = UIListContentConfiguration.header()
      content.text = dataSource.snapshot().sectionIdentifiers[path.section]
      header.contentConfiguration = content
    }
    dataSource.supplementaryViewProvider = { collection, _, path in
      collection.dequeueConfiguredReusableSupplementary(using: headers, for: path)
    }
  }

  func update(groups: [Group], selected: ResultID?, focusRequest: UUID) {
    loadViewIfNeeded()
    let previousResults = results
    self.selected = selected
    results = Dictionary(groups.flatMap(\.results).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let wantsFocus = self.focusRequest != focusRequest
    self.focusRequest = focusRequest
    var snapshot = NSDiffableDataSourceSnapshot<String, ResultID>()
    for group in groups {
      snapshot.appendSections([group.title])
      snapshot.appendItems(group.results.map(\.id), toSection: group.title)
    }
    let previous = Set(dataSource.snapshot().itemIdentifiers)
    // 只重配内容变化的行（头像到达、打开中状态），避免整表闪动。
    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) && previousResults[$0] != results[$0] })
    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      guard let self else { return }
      if let selected = self.selected, let path = dataSource.indexPath(for: selected) {
        collectionView.selectItem(at: path, animated: false, scrollPosition: [])
      } else {
        for path in collectionView.indexPathsForSelectedItems ?? [] { collectionView.deselectItem(at: path, animated: false) }
      }
      guard wantsFocus, self.focusRequest == focusRequest,
            let target = self.selected ?? dataSource.snapshot().itemIdentifiers.first,
            let path = dataSource.indexPath(for: target) else { return }
      collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
      collectionView.layoutIfNeeded()
      // Catalyst 的焦点遍历会跳过嵌套结果列表；由结果控制器承接方向键。
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self, self.focusRequest == focusRequest, self.view.window != nil,
              self.dataSource.indexPath(for: target) != nil else { return }
        activate(target)
        _ = becomeFirstResponder()
      }
    }
  }

  override var canBecomeFirstResponder: Bool { true }
  override var keyCommands: [UIKeyCommand]? {
    guard isFirstResponder else { return nil }
    return [
      UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousResult)),
      UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextResult)),
      UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(openSelectedResult)),
      UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(focusSearchField)),
    ].map { command in command.wantsPriorityOverSystemBehavior = true; return command }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    resignFirstResponder()
  }
  @objc private func focusSearchField() { resignFirstResponder(); returnToSearch?() }
  @objc private func previousResult() { moveSelection(-1) }
  @objc private func nextResult() { moveSelection(1) }
  @objc private func openSelectedResult() { if let selected { activate(selected) } }
  private func moveSelection(_ offset: Int) {
    let rows = dataSource.snapshot().itemIdentifiers
    guard !rows.isEmpty else { return }
    let index = selected.flatMap { rows.firstIndex(of: $0) } ?? (offset > 0 ? -1 : rows.count)
    let next = min(max(index + offset, 0), rows.count - 1)
    guard rows[next] != selected else { return }
    activate(rows[next])
  }
  private func activate(_ id: ResultID) {
    guard let path = dataSource.indexPath(for: id) else { return }
    selected = id
    collectionView.selectItem(at: path, animated: false, scrollPosition: .centeredVertically)
    select?(id)
  }

  override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
    selected = id
    select?(id)
  }
  override func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
    guard let path = context.nextFocusedIndexPath, let id = dataSource.itemIdentifier(for: path), selected != id else { return }
    selected = id
    select?(id)
  }
}
