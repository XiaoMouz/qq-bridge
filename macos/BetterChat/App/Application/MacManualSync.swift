import Foundation
import Observation

/// 同步由设置页发起，状态必须跨标签可见；离开工作区后旧任务不能再更新新页面。
@MainActor
@Observable
final class MacManualSync {
  private(set) var isRunning = false
  var error: String?
  private var task: Task<Void, Never>?
  private var generation = UUID()

  func start(operation: @escaping @MainActor () async throws -> Void, completed: @escaping @MainActor () -> Void) {
    guard task == nil else { return }
    error = nil
    isRunning = true
    let id = UUID()
    generation = id
    task = Task { [weak self] in
      do {
        try await operation()
        guard !Task.isCancelled, let self, self.generation == id else { return }
        self.task = nil
        self.isRunning = false
        completed()
      } catch {
        guard !Task.isCancelled, let self, self.generation == id else { return }
        self.task = nil
        self.isRunning = false
        if !(error is CancellationError) { self.error = String(describing: error) }
      }
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isRunning = false
    error = nil
  }
}
