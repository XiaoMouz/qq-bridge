import Foundation
import Observation
import QQBridgeKit

@MainActor
protocol ChatHistoryPagingService {
  func localCount() throws -> Int
  func loadOlder(limit: UInt32) async throws -> Int
}

@MainActor
struct SessionChatHistoryPagingService: ChatHistoryPagingService {
  let session: Session
  let chatId: Int64
  func localCount() throws -> Int { try session.store.loadedWindow(chatId: chatId).count }
  func loadOlder(limit: UInt32) async throws -> Int { try await session.sync.loadOlder(chatId, limit: limit) }
}

/// 滚动触发失败后停下来等明确重试，避免鼠标停在列表边缘时反复请求。
@MainActor @Observable
final class ChatHistoryPagination {
  private(set) var limit = 60
  private(set) var isLoading = false
  private(set) var reachedStart = false
  private(set) var error: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var resumeOnReturn = false

  deinit { task?.cancel() }

  @discardableResult
  func load(using service: any ChatHistoryPagingService, retry: Bool = false) -> Task<Void, Never>? {
    if let task { return task }
    guard error == nil || retry else { return nil }
    error = nil
    do {
      if try service.localCount() > limit {
        limit += 60
        return nil
      }
    } catch {
      self.error = LoadState.describe(error)
      return nil
    }
    // 服务端已到头，不代表本地连续区间已经全部展示（跳转不存在的旧消息时会遇到）。
    guard !reachedStart else { return nil }
    isLoading = true
    resumeOnReturn = false
    let request = generation
    let next = Task { [weak self, service] in
      do {
        let count = try await service.loadOlder(limit: 60)
        guard let self, generation == request, !Task.isCancelled else { return }
        recordOlderPage(count)
        isLoading = false
        task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        self.error = (error as? URLError)?.code == .timedOut ? "加载超时，请重试" : LoadState.describe(error)
        isLoading = false
        task = nil
      }
    }
    task = next
    return next
  }

  func includeNewMessages(_ count: Int) { limit += max(0, count) }
  func reveal(through count: Int) { limit = max(limit, count) }
  func recordOlderPage(_ count: Int) {
    if count == 0 { reachedStart = true }
    else { limit += max(0, count) }
  }

  func recordLoadedWindow(_ count: Int, exhausted: Bool) {
    reveal(through: count)
    reachedStart = exhausted
  }

  func prepareForJump() {
    cancel()
    resumeOnReturn = false
    error = nil
  }

  func trim() {
    cancel()
    resumeOnReturn = false
    limit = 60
    reachedStart = false
    error = nil
  }

  func cancel() {
    if task != nil { resumeOnReturn = true }
    generation = UUID()
    task?.cancel()
    task = nil
    isLoading = false
  }

  @discardableResult
  func resume(using service: any ChatHistoryPagingService) -> Task<Void, Never>? {
    guard resumeOnReturn else { return nil }
    resumeOnReturn = false
    return load(using: service)
  }
}
