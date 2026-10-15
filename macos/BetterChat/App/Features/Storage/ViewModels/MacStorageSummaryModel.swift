import Foundation
import Observation

/// 会话统计和类型详情均是完整快照：刷新失败保留旧值，离开后拒绝迟到响应。
@MainActor @Observable
final class MacStorageSummaryModel<Value: Sendable> {
  private(set) var value: Value?
  private(set) var isLoading = false
  private(set) var error: String?
  @ObservationIgnored private let fetch: @MainActor () async throws -> Value
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(fetch: @escaping @MainActor () async throws -> Value) { self.fetch = fetch }
  deinit { task?.cancel() }

  func start() { if value == nil, error == nil { reload() } }

  @discardableResult func reload() -> Task<Void, Never> {
    if let task { return task }
    isLoading = true; error = nil
    let request = generation
    let work = Task { [weak self, fetch] in
      do {
        let result = try await fetch()
        guard let self, generation == request, !Task.isCancelled else { return }
        value = result; isLoading = false; task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        self.error = MacStorageFailure.describe(error); isLoading = false; task = nil
      }
    }
    task = work
    return work
  }

  func cancel() {
    generation = UUID(); task?.cancel(); task = nil; isLoading = false
  }
}
