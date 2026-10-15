import Foundation
import Observation
import QQBridgeKit

/// 首屏与刷新共用一份请求状态。刷新失败保留已显示的内容，离开页面使旧请求失效。
@MainActor @Observable
final class MacGroupListViewModel<Item: Sendable> {
  private(set) var items: [Item] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var error: String?
  @ObservationIgnored private let service: any MacGroupListService<Item>
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(service: any MacGroupListService<Item>) { self.service = service }
  deinit { task?.cancel() }

  func start() {
    guard !hasLoaded, error == nil else { return }
    load()
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    if let task { return task }
    isLoading = true
    error = nil
    let request = generation
    let next = Task { [weak self, service] in
      do {
        let result = try await service.load()
        guard let self, generation == request, !Task.isCancelled else { return }
        items = result
        hasLoaded = true
        isLoading = false
        task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        if (error as? URLError)?.code == .timedOut || (error as? APIError)?.code == .deadlineExceeded {
          self.error = "加载超时，请重试"
        } else {
          self.error = LoadState.describe(error)
        }
        isLoading = false
        task = nil
      }
    }
    task = next
    return next
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isLoading = false
  }
}
