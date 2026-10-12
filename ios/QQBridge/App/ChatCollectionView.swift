// 消息列表（docs/design.md 6.1）：UICollectionView + 可比较数据源，单元格用 UIHostingConfiguration 渲染 SwiftUI 气泡。
//
// 列表是倒过来的（和 Telegram 一样）：整个集合视图上下翻转，每个单元格再翻回来，最新的消息排在第 0 个、显示在最下面。
// 这样位置是以"最新的消息 / 最底部"为基准算的：
// - 往上翻时，更早的单元格算出真实高度（长文字、图片撑开）只影响更早的部分，正在看的内容不会被推着跳；
// - 往上翻页加载更早的消息是在列表末尾追加，不用再手动修正滚动位置；
// - 停在最底部 = 偏移量在起点，新消息来了自然就在眼前。
// 坐标里的"上 / 下"因此是反的：contentOffset 越小越靠近最新的消息。
import QQBridgeKit
import QQBridgeProto
import SwiftUI
import UIKit

/// 外面要列表滚到哪里（token 变了才执行一次）：某条消息居中，或回到最底部。
struct ChatScrollRequest: Equatable {
  enum Target: Equatable {
    case item(String)
    case bottom
  }

  let target: Target
  let token = UUID()
}

struct ChatCollectionView: UIViewControllerRepresentable {
  /// 按时间升序（最旧的在前）。
  let items: [ChatItem]
  /// items 每变一次加一：外面别的状态变化（打字、按钮出现）不会让列表重新比对、提交。
  let version: Int
  let context: MessageContext
  let onReachTop: () -> Void
  /// 是否停在最底部（标已读、回到底部按钮用）。
  var onBottomChange: (Bool) -> Void = { _ in }
  /// 现在屏幕上看得到的消息 seq（"有人@我"据此把看过的移掉）。
  var onVisibleSeqs: (Set<Int64>) -> Void = { _ in }
  /// 用户在滚动时，屏幕最上面那条的时间（顶部日期徽章用）；停下后 nil。
  var onScrollDate: (Int64?) -> Void = { _ in }
  var scrollRequest: ChatScrollRequest?

  func makeUIViewController(context _: Context) -> ChatCollectionController {
    ChatCollectionController()
  }

  func updateUIViewController(_ controller: ChatCollectionController, context _: Context) {
    controller.messageContext = context
    controller.onReachTop = onReachTop
    controller.onBottomChange = onBottomChange
    controller.onVisibleSeqs = onVisibleSeqs
    controller.onScrollDate = onScrollDate
    controller.request(scrollRequest)
    controller.apply(items, version: version)
  }
}

@MainActor
final class ChatCollectionController: UIViewController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
  var messageContext: MessageContext?
  var onScrollDate: ((Int64?) -> Void)?
  var onReachTop: (() -> Void)?
  var onBottomChange: ((Bool) -> Void)?
  var onVisibleSeqs: ((Set<Int64>) -> Void)?
  private var reportedBottom: Bool?
  private var reportedVisible: Set<Int64> = []

  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
  private var byId: [String: ChatItem] = [:]
  /// 每一项的前一项（时间上更早的那条）：显示时间、发送者头像时要用，提交数据时一次算好。
  private var previousById: [String: ChatItem] = [:]
  private var appliedVersion = -1
  private var handledRequest: UUID?
  /// 还没执行的滚动请求（目标消息还没进列表时先等着）。
  private var pendingRequest: ChatScrollRequest?
  /// 正在执行的跳转：滚动结束后再按真实高度校正一次。
  private var jumpTarget: String?
  /// 正在执行的滚动动画（回到底部 / 跳到某条）：期间不按锚点校正位置（直接设偏移量会把动画打断，停在半路）。
  private var animatingTo: ChatScrollRequest.Target?

  private static let flip = CGAffineTransform(scaleX: 1, y: -1)

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
    collectionView.transform = Self.flip
    // 翻转后系统自动加的安全区内边距方向是反的：自己按翻转后的方向设。
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.automaticallyAdjustsScrollIndicatorInsets = false
    // 点状态栏回顶：翻转后会滚到最新的消息，不对，关掉。
    collectionView.scrollsToTop = false
    view.addSubview(collectionView)

    let cell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
      guard let self, let item = self.byId[id], let context = self.messageContext else { return }
      cell.contentConfiguration = UIHostingConfiguration {
        MessageRow(item: item, context: context, previous: self.previousById[id])
      }
      .margins(.horizontal, 12)
      .margins(.vertical, 2)
      cell.backgroundConfiguration = .clear()
      cell.contentView.transform = Self.flip
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, id in
      cv.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
    }

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.delegate = self
    collectionView.addGestureRecognizer(pan)
    replyArrow.tintColor = .secondaryLabel
    replyArrow.transform = Self.flip
    replyArrow.alpha = 0
    collectionView.addSubview(replyArrow)
  }

  // MARK: 横向拖动：按在气泡上拖 = 回复这条；按在空白处拖 = 露出时间

  private enum PanMode {
    case times
    case reply(cell: UICollectionViewCell, message: Qqbridge_V1_Message)
  }

  private var panMode: PanMode?
  private let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.circle.fill",
                                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)))
  private static let replyThreshold: CGFloat = 64
  private var replyArmed = false

  func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    guard let pan = g as? UIPanGestureRecognizer, pan.view === collectionView else { return true }
    guard !selecting else { return false }
    let v = pan.velocity(in: collectionView)
    // 只认往左、明显横向的拖动（往右是系统的返回手势）。
    guard v.x < 0, abs(v.x) > abs(v.y) * 1.5 else { return false }
    let p = pan.location(in: collectionView)
    if let indexPath = collectionView.indexPathForItem(at: p), let cell = collectionView.cellForItem(at: indexPath),
      let id = dataSource.itemIdentifier(for: indexPath), case .message(let m)? = byId[id], m.state != .recalled,
      let bubble = messageContext?.bubbleFrames.frame(m.seq)
    {
      // 行内坐标 = 单元格内容坐标减去边距（左右 12、上下 2）；UIKit 换算时已经处理了翻转。
      let local = pan.location(in: cell.contentView)
      if bubble.insetBy(dx: -4, dy: -4).contains(CGPoint(x: local.x - 12, y: local.y - 2)) {
        panMode = .reply(cell: cell, message: m)
        return true
      }
    }
    panMode = .times
    return true
  }

  @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
    guard let mode = panMode else { return }
    let dx = min(0, pan.translation(in: collectionView).x)
    switch mode {
    case .times:
      let reveal = min(TimeReveal.width, -dx * 0.6)
      switch pan.state {
      case .changed: messageContext?.timeReveal.offset = reveal
      default:
        UIView.animate(withDuration: 0.25) { self.messageContext?.timeReveal.offset = 0 }
        if pan.state != .changed { panMode = nil }
      }
    case .reply(let cell, let message):
      let shift = max(dx, -Self.replyThreshold * 1.4)
      switch pan.state {
      case .began, .changed:
        cell.contentView.transform = Self.flip.translatedBy(x: shift * 0.85, y: 0)
        replyArrow.center = CGPoint(x: cell.frame.maxX - 28, y: cell.frame.midY)
        replyArrow.alpha = min(1, -shift / Self.replyThreshold)
        let armed = -shift >= Self.replyThreshold
        if armed, !replyArmed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        replyArmed = armed
      default:
        if replyArmed, pan.state == .ended { messageContext?.actions.reply(message) }
        replyArmed = false
        panMode = nil
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
          cell.contentView.transform = Self.flip
          self.replyArrow.alpha = 0
        }
      }
    }
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    updateInsets()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateInsets()
  }

  /// 翻转后：内容的"顶"在屏幕底部（输入栏、键盘那边），"底"在屏幕顶部（导航栏那边）。
  private func updateInsets() {
    let safe = view.safeAreaInsets
    let insets = UIEdgeInsets(top: safe.bottom + 4, left: 0, bottom: safe.top + 4, right: 0)
    guard collectionView.contentInset != insets else { return }
    let wasAtBottom = isAtBottom
    collectionView.contentInset = insets
    collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: safe.bottom, left: 0, bottom: safe.top, right: 0)
    // 键盘弹出、输入栏变高时：本来在最底部就继续贴着。
    if wasAtBottom { scrollToBottom(animated: false) }
  }

  // MARK: 数据

  func apply(_ items: [ChatItem], version: Int) {
    guard version != appliedVersion else { return }
    appliedVersion = version
    let oldIds = dataSource.snapshot().itemIdentifiers
    let changed = items.filter { byId[$0.id] != $0 }.map(\.id)
    byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    var previous: [String: ChatItem] = [:]
    for i in items.indices.dropFirst() { previous[items[i].id] = items[i - 1] }
    // 某一项的前一项变了（例如中间插进了一条），它的时间、头像显示可能要变：一起刷新。
    let previousChanged = items.indices.dropFirst().compactMap { i -> String? in
      previousById[items[i].id]?.id == items[i - 1].id ? nil : items[i].id
    }
    previousById = previous

    let ids = Array(items.map(\.id).reversed())
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(ids)
    let old = Set(oldIds)
    snapshot.reconfigureItems(Array(Set(changed + previousChanged).filter { old.contains($0) && byId[$0] != nil }))

    // 不在底部时（往上翻着看历史）：不管底下来了新消息、顶上收掉了旧消息，还是中间的消息高度变了，
    // 都以屏幕上一条正在看的消息为锚点，提交后把它放回原来的屏幕位置，正在看的内容不跳。
    let keep = !oldIds.isEmpty && animatingTo == nil && (!isAtBottom || selecting)
    let anchor = keep ? visibleAnchor() : nil

    dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
      guard let self else { return }
      if let anchor { self.restore(anchor) }
      self.performPendingRequest()
      self.reportPosition()
    }
  }

  /// 锚点：屏幕中间那条可见消息的 id，以及它的顶边相对可见区域的位置。
  private func visibleAnchor() -> (id: String, offset: CGFloat)? {
    let mid = collectionView.contentOffset.y + collectionView.bounds.height / 2
    let visible = collectionView.indexPathsForVisibleItems.compactMap { ip -> (String, CGRect)? in
      guard let id = dataSource.itemIdentifier(for: ip), let attrs = collectionView.layoutAttributesForItem(at: ip) else { return nil }
      return (id, attrs.frame)
    }
    guard let best = visible.min(by: { abs($0.1.midY - mid) < abs($1.1.midY - mid) }) else { return nil }
    return (best.0, best.1.minY - collectionView.contentOffset.y)
  }

  private func restore(_ anchor: (id: String, offset: CGFloat)) {
    guard let indexPath = dataSource.indexPath(for: anchor.id) else { return }
    collectionView.layoutIfNeeded()
    guard let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
    let target = attrs.frame.minY - anchor.offset
    // 差不到半个点就不动（直接设 contentOffset 会打断正在进行的惯性滚动）。
    if abs(collectionView.contentOffset.y - target) > 0.5 { collectionView.contentOffset.y = target }
  }

  private var selecting: Bool { messageContext?.selection.active ?? false }

  // MARK: 滚动

  func request(_ r: ChatScrollRequest?) {
    guard let r, r.token != handledRequest else { return }
    handledRequest = r.token
    pendingRequest = r
    performPendingRequest()
  }

  private func performPendingRequest() {
    guard let r = pendingRequest, collectionView != nil else { return }
    switch r.target {
    case .bottom:
      pendingRequest = nil
      animatingTo = .bottom
      scrollToBottom(animated: true)
    case .item(let id):
      guard let indexPath = dataSource.indexPath(for: id) else { return }
      pendingRequest = nil
      jumpTarget = id
      animatingTo = r.target
      collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
    }
  }

  /// 跳转时目标附近的单元格是按估算高度排的：滚完后它们算出了真实高度，目标可能偏了，再无动画校正一次。
  private func finishJump() {
    guard let id = jumpTarget else { return }
    jumpTarget = nil
    guard let indexPath = dataSource.indexPath(for: id) else { return }
    collectionView.layoutIfNeeded()
    collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
  }

  private var isAtBottom: Bool {
    guard let cv = collectionView else { return true }
    return cv.contentOffset.y <= -cv.contentInset.top + 120
  }

  private func scrollToBottom(animated: Bool) {
    collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: animated)
  }

  private func reportPosition() {
    let bottom = isAtBottom
    if bottom != reportedBottom {
      reportedBottom = bottom
      onBottomChange?(bottom)
    }
    // 完整露出一半以上才算"看到了"。
    let visibleRect = collectionView.bounds.inset(by: collectionView.contentInset)
    var seqs: Set<Int64> = []
    for indexPath in collectionView.indexPathsForVisibleItems {
      guard let attrs = collectionView.layoutAttributesForItem(at: indexPath),
        attrs.frame.intersection(visibleRect).height >= min(attrs.frame.height, visibleRect.height) * 0.5,
        let id = dataSource.itemIdentifier(for: indexPath),
        case .message(let m)? = byId[id]
      else { continue }
      seqs.insert(m.seq)
    }
    if seqs != reportedVisible {
      reportedVisible = seqs
      onVisibleSeqs?(seqs)
    }
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // 翻转后更早的消息在内容的末尾：离末尾不远就往前翻页。
    let remaining = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
    if scrollView.isTracking || scrollView.isDecelerating, remaining < 600 { onReachTop?() }
    reportPosition()
    if scrollView.isTracking || scrollView.isDecelerating, !isAtBottom { reportTopDate() }
  }

  /// 屏幕最上面那条（倒过来的列表里 index 最大的可见项）的时间。
  private func reportTopDate() {
    guard let top = collectionView.indexPathsForVisibleItems.max(by: { $0.item < $1.item }),
      let id = dataSource.itemIdentifier(for: top), let item = byId[id]
    else { return }
    onScrollDate?(item.time)
  }

  /// 用户自己拖了：程序发起的滚动动画作废。
  func scrollViewWillBeginDragging(_: UIScrollView) {
    animatingTo = nil
  }

  func scrollViewDidEndDecelerating(_: UIScrollView) {
    onScrollDate?(nil)
  }

  func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { onScrollDate?(nil) }
  }

  func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
    // 动画途中底下又来了消息、高度变了：落到真正的最底部。
    if animatingTo == .bottom { scrollToBottom(animated: false) }
    animatingTo = nil
    finishJump()
    reportPosition()
  }

  func collectionView(_: UICollectionView, shouldSelectItemAt _: IndexPath) -> Bool { false }
}
