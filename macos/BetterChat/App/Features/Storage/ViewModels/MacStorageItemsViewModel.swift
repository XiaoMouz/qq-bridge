import Foundation
import Observation

/// offset 按服务端实际返回条数推进，不能用去重后的网格数量推算下一页。
@MainActor @Observable
final class MacStorageItemsViewModel {
  private(set) var items: [StorageItemModel] = []
  private(set) var hasMore = true
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  private(set) var error: String?
  @ObservationIgnored private let service: any MacStorageItemsService
  @ObservationIgnored private var offset: UInt32 = 0
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?

  init(service: any MacStorageItemsService) { self.service = service }
  deinit { task?.cancel() }

  func start() { if !hasLoaded, error == nil { loadMore() } }
  func reached(_ id: String) {
    guard error == nil, id == items.last?.id else { return }
    loadMore()
  }

  @discardableResult
  func loadMore() -> Task<Void, Never>? {
    guard !isLoading, hasMore else { return nil }
    isLoading = true; error = nil
    let request = generation, offset = offset
    let work = Task { [weak self, service] in
      do {
        let page = try await service.page(offset: offset)
        guard let self, generation == request, !Task.isCancelled else { return }
        // 该接口只有 offset，没有独立游标；空页声称 more 无法安全继续，保留原 offset 重试。
        guard !page.more || !page.items.isEmpty else {
          error = "未能加载下一页，请重试"; isLoading = false; task = nil; return
        }
        var indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        for item in page.items {
          if let index = indices[item.id] { items[index] = item }
          else { indices[item.id] = items.count; items.append(item) }
        }
        self.offset += UInt32(page.items.count)
        hasMore = page.more; hasLoaded = true; isLoading = false; task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        self.error = MacStorageFailure.describe(error)
        isLoading = false; task = nil
      }
    }
    task = work
    return work
  }

  func cancel() {
    generation = UUID(); task?.cancel(); task = nil; isLoading = false
  }
}
