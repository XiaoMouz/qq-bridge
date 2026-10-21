import UIKit
import UniformTypeIdentifiers

/// 文件进入草稿，不插入消息数据源；也不移动 Finder 的原文件。
@MainActor
final class MacChatFileDropReceiver: NSObject, UICollectionViewDropDelegate {
  var onDrop: (([NSItemProvider]) -> Void)?
  var onTargeted: ((Bool) -> Void)?
  private var targeted = false
  /// 拖动停在聊天上时系统会一直发更新；超过这么久没收到更新就当拖动已经结束，收掉提示。
  /// 2026-10-21 用户反馈：@、加图片、回复后偶尔留下一层蒙层（就是这个「松手添加附件」），拖出 / 结束的回调有时收不到。
  private var lastUpdate = Date.distantPast
  private var watchdog: Timer?

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    // 本 App 里开始的拖动（输入框、气泡里选中的文字被拖动）不算拖入附件：以前它们也会点亮提示，而且常常收不到结束回调。
    guard session.localDragSession == nil else { return false }
    let accepted = canHandle(session.items.map(\.itemProvider))
    #if DEBUG
    MacDropDiagnostics.record("UIKit collection canHandle=\(accepted) count=\(session.items.count) types=\(session.items.flatMap { $0.itemProvider.registeredTypeIdentifiers })")
    #endif
    return accepted
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                      withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
    let accepted = session.localDragSession == nil && canHandle(session.items.map(\.itemProvider))
    lastUpdate = Date()
    setTargeted(accepted)
    return UICollectionViewDropProposal(operation: accepted ? .copy : .forbidden, intent: .unspecified)
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidExit session: UIDropSession) {
    setTargeted(false)
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) {
    setTargeted(false)
  }

  func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
    receive(coordinator.items.map { $0.dragItem.itemProvider })
  }

  func canHandle(_ providers: [NSItemProvider]) -> Bool {
    onDrop != nil && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.item.identifier) }
  }

  func receive(_ providers: [NSItemProvider]) {
    setTargeted(false)
    #if DEBUG
    MacDropDiagnostics.record("UIKit collection perform count=\(providers.count)")
    #endif
    onDrop?(providers)
  }

  private func setTargeted(_ value: Bool) {
    guard targeted != value else { return }
    targeted = value
    watchdog?.invalidate()
    watchdog = nil
    if value {
      // AppKit 的拖动在原地不动时也会定期发更新；1.5 秒都没有，说明拖动已经不在聊天上了。
      watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, Date().timeIntervalSince(self.lastUpdate) > 1.5 else { return }
          self.setTargeted(false)
        }
      }
    }
    #if DEBUG
    MacDropDiagnostics.record("UIKit collection targeted=\(value)")
    #endif
    onTargeted?(value)
  }
}
