import Foundation
import Observation

/// 群资料和成员缓存共用的请求归属；切群清掉旧值，刷新同群失败保留已加载值。
@MainActor @Observable
final class MacGroupResource<Value: Sendable> {
  private(set) var value: Value?
  private(set) var groupID: Int64?
  private(set) var error: String?
  private(set) var isLoading = false
  var hasLoaded: Bool { value != nil }
  @ObservationIgnored private var request: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  deinit { request?.cancel() }

  @discardableResult
  func load(groupID: Int64, fetch: @escaping @MainActor () async throws -> Value) -> Task<Void, Never> {
    if self.groupID == groupID, let request { return request }
    cancel()
    if self.groupID != groupID { value = nil }
    self.groupID = groupID
    error = nil
    isLoading = true
    let id = generation
    let task = Task { [weak self] in
      do {
        let result = try await fetch()
        guard let self, generation == id, !Task.isCancelled else { return }
        value = result
        finish()
      } catch {
        guard let self, generation == id, !Task.isCancelled else { return }
        self.error = Self.describe(error)
        finish()
      }
    }
    request = task
    return task
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    finish()
  }

  private func finish() {
    request = nil
    isLoading = false
  }

  private static func describe(_ error: any Error) -> String {
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet, .networkConnectionLost: return "网络连接已中断，请重试"
      case .timedOut: return "加载超时，请重试"
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接服务器，请重试"
      default: break
      }
    }
    return LoadState.describe(error)
  }
}
