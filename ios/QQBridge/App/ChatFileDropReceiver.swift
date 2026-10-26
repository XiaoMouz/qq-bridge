import UIKit
import UniformTypeIdentifiers

/// 从外部拖进聊天的文件、媒体：进草稿（不插入消息数据源，也不移动 Finder 的原文件），拖在聊天上时点亮拖入提示。
/// iOS 和 Mac 共用，挂在聊天列表上（UIKit 的拖放接口才能关掉系统的读取进度蒙层，见 progressIndicatorStyle）。
@MainActor
final class ChatFileDropReceiver: NSObject, UICollectionViewDropDelegate {
  var onDrop: (([NSItemProvider]) -> Void)?
  var onTargeted: ((Bool) -> Void)?
  private var targeted = false
  /// 拖动停在聊天上时系统会一直发更新；超过这么久没收到更新就当拖动已经结束，收掉提示。
  /// 2026-10-21 用户反馈拖出 / 结束的回调有时收不到，提示会留着。
  private var lastUpdate = Date.distantPast
  private var watchdog: Timer?

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    // 本 App 里开始的拖动（输入框、气泡里选中的文字被拖动）不算拖入附件。
    guard session.localDragSession == nil else { return false }
    let accepted = canHandle(session.items.map(\.itemProvider))
    #if DEBUG && targetEnvironment(macCatalyst)
    MacDropDiagnostics.record("UIKit collection canHandle=\(accepted) count=\(session.items.count) types=\(session.items.flatMap { $0.itemProvider.registeredTypeIdentifiers })")
    #endif
    return accepted
  }

  func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                      withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
    let accepted = session.localDragSession == nil && canHandle(session.items.map(\.itemProvider))
    // 不要系统的读取进度：它在拖入的大文件读完前给整个聊天列表盖一层模糊蒙层，读得慢就一直盖着
    // （2026-10-26 用户截图：iPhone、Mac 拖入文件上传时聊天被整层模糊）。进度由附件条上的进度环表示。
    session.progressIndicatorStyle = .none
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
    coordinator.session.progressIndicatorStyle = .none
    receive(coordinator.items.map { $0.dragItem.itemProvider })
  }

  func canHandle(_ providers: [NSItemProvider]) -> Bool {
    onDrop != nil && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.item.identifier) }
  }

  func receive(_ providers: [NSItemProvider]) {
    setTargeted(false)
    #if DEBUG && targetEnvironment(macCatalyst)
    MacDropDiagnostics.record("UIKit collection perform count=\(providers.count)")
    #endif
    onDrop?(providers)
  }

  /// 页面消失、回到前台等场合由外面直接收掉。
  func reset() { setTargeted(false) }

  private func setTargeted(_ value: Bool) {
    guard targeted != value else { return }
    targeted = value
    watchdog?.invalidate()
    watchdog = nil
    if value {
      // 拖动停在原地时系统也会定期发更新；1.5 秒都没有，说明拖动已经不在聊天上了。
      watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, Date().timeIntervalSince(self.lastUpdate) > 1.5 else { return }
          self.setTargeted(false)
        }
      }
    }
    onTargeted?(value)
  }
}
