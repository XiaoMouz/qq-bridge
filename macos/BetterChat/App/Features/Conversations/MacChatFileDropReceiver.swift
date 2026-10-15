import UIKit
import UniformTypeIdentifiers

/// 文件进入草稿，不插入消息数据源；也不移动 Finder 的原文件。
@MainActor
final class MacChatFileDropReceiver: NSObject, UICollectionViewDropDelegate {
  var onDrop: (([NSItemProvider]) -> Void)?
  var onTargeted: ((Bool) -> Void)?
  private var targeted = false

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    let accepted = canHandle(session.items.map(\.itemProvider))
    #if DEBUG
    MacDropDiagnostics.record("UIKit collection canHandle=\(accepted) count=\(session.items.count) types=\(session.items.flatMap { $0.itemProvider.registeredTypeIdentifiers })")
    #endif
    return accepted
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                      withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
    let accepted = canHandle(session.items.map(\.itemProvider))
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
    #if DEBUG
    MacDropDiagnostics.record("UIKit collection targeted=\(value)")
    #endif
    onTargeted?(value)
  }
}
