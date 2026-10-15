import CoreTransferable
import Foundation

@MainActor
enum MacDroppedProviders {
  static func enqueue(_ providers: [NSItemProvider], into queue: AttachmentQueue<Attachment>) {
    guard !providers.isEmpty else {
      queue.importError = "无法读取拖入的文件，请重新拖入，或使用“添加附件”选择文件。"
      return
    }
    // 松手时锁定草稿队列；异步读取期间切换会话也不能把附件放进另一份草稿。
    // UIKit 要求在 performDrop 回调内发起数据读取；不能等队列 Task 开始后才请求提供器。
    let transfers = providers.map(start)
    queue.enqueueImport { await load(transfers: transfers) }
  }

  static func load(_ providers: [NSItemProvider]) async -> AttachmentLoader.FileImportResult {
    await load(transfers: providers.map(start))
  }

  private static func start(_ provider: NSItemProvider) -> AsyncThrowingStream<DroppedItem, Error> {
    let (stream, continuation) = AsyncThrowingStream<DroppedItem, Error>.makeStream()
    _ = provider.loadTransferable(type: DroppedItem.self) { result in
      switch result {
      case .success(let item):
        continuation.yield(item)
        continuation.finish()
      case .failure(let error):
        continuation.finish(throwing: error)
      }
    }
    return stream
  }

  private static func load(transfers: [AsyncThrowingStream<DroppedItem, Error>]) async -> AttachmentLoader.FileImportResult {
    var result = AttachmentLoader.FileImportResult()
    for (index, transfer) in transfers.enumerated() {
      do {
        for try await item in transfer {
          let imported = await AttachmentLoader.load(drops: [item])
          result.attachments.append(contentsOf: imported.attachments)
          result.failures.append(contentsOf: imported.failures)
        }
      } catch {
        result.failures.append("第 \(index + 1) 项附件：\(error.localizedDescription)")
      }
    }
    #if DEBUG
    MacDropDiagnostics.record("UIKit import finished attachments=\(result.attachments.count) failures=\(result.failures.count)")
    #endif
    return result
  }
}
