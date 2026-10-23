import UIKit
import UniformTypeIdentifiers

/// 文件进入草稿，不插入消息数据源；也不移动 Finder 的原文件。
@MainActor
final class MacChatFileDropReceiver: NSObject, UICollectionViewDropDelegate {
  var onDrop: (([NSItemProvider]) -> Void)?

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    // 本 App 里开始的拖动（输入框、气泡里选中的文字被拖动）不算拖入附件。
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
    return UICollectionViewDropProposal(operation: accepted ? .copy : .forbidden, intent: .unspecified)
  }

  func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
    receive(coordinator.items.map { $0.dragItem.itemProvider })
  }

  func canHandle(_ providers: [NSItemProvider]) -> Bool {
    onDrop != nil && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.item.identifier) }
  }

  func receive(_ providers: [NSItemProvider]) {
    #if DEBUG
    MacDropDiagnostics.record("UIKit collection perform count=\(providers.count)")
    #endif
    onDrop?(providers)
  }
}
