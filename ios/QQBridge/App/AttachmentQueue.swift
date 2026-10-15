import Foundation
import Observation

/// 草稿页面可以更换，附件和正在执行的批次必须保持同一个所有者。
@MainActor
@Observable
final class AttachmentQueue<Item> {
  var items: [Item] = []
  var error: String? { didSet { errorSourceID = nil } }
  private var errorSourceID: UUID?
  var importError: String?
  private(set) var pendingImports = 0
  @ObservationIgnored private var lastImport: Task<Void, Never>?

  func recordError(_ message: String, sourceID: UUID) {
    error = message
    errorSourceID = sourceID
  }

  func clearError(resolvedIDs: Set<UUID>) {
    guard let errorSourceID, resolvedIDs.contains(errorSourceID) else { return }
    error = nil
  }

  func enqueueImport(_ operation: @escaping @MainActor () async -> AttachmentImportResult<Item>,
                     completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
    let previous = lastImport
    pendingImports += 1
    lastImport = Task {
      // 先读取每批来源，再按用户添加顺序提交；慢视频不能让后加的文件抢到前面。
      let result = await operation()
      await previous?.value
      items.append(contentsOf: result.attachments)
      if let failure = result.errorMessage {
        importError = [importError, failure].compactMap { $0 }.joined(separator: "\n")
      }
      pendingImports -= 1
      if pendingImports == 0 { lastImport = nil }
      completion(!result.attachments.isEmpty && result.failures.isEmpty)
    }
  }
  private(set) var isSending = false

  @discardableResult
  func start(_ operation: @escaping @MainActor () async throws -> Void) -> Bool {
    guard !isSending else { return false }
    isSending = true
    error = nil
    // 任务持有队列直到收尾，关闭快速回复不能让上传结果失去归属。
    Task {
      defer { isSending = false }
      do { try await operation() }
      catch { self.error = error.localizedDescription }
    }
    return true
  }
}

struct AttachmentImportResult<Item> {
  var attachments: [Item] = []
  var failures: [String] = []
  var errorMessage: String? {
    guard !failures.isEmpty else { return nil }
    let details = failures.prefix(3).joined(separator: "\n")
    return failures.count > 3 ? details + "\n另有 \(failures.count - 3) 项未能添加" : details
  }
}
