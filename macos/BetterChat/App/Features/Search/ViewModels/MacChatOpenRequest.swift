import Foundation
import Observation

/// 打开尚无会话的联系人需要等待服务端；过期选择不能抢走用户后来切换的页面。
@MainActor
@Observable
final class MacChatOpenRequest {
  private(set) var peerKey: String?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?

  // 搜索 ViewModel 和转发选择页持有此对象；释放时收掉仍在等待的请求。
  // 迟到的结果另有 generation 判断，取消产生的 CancellationError 不会作为失败上报。
  deinit { task?.cancel() }

  func start(peerKey: String, operation: @escaping @MainActor () async throws -> Int64,
             opened: @escaping @MainActor (Int64) -> Void,
             failed: @escaping @MainActor (any Error) -> Void) {
    guard self.peerKey != peerKey else { return }
    cancel()
    self.peerKey = peerKey
    let generation = self.generation
    task = Task { [weak self] in
      do {
        let id = try await operation()
        guard let self, self.generation == generation, !Task.isCancelled else { return }
        self.peerKey = nil
        self.task = nil
        opened(id)
      } catch {
        guard let self, self.generation == generation, !Task.isCancelled else { return }
        self.peerKey = nil
        self.task = nil
        if !(error is CancellationError) { failed(error) }
      }
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    peerKey = nil
  }
}
