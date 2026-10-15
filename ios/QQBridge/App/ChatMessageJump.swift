import Foundation
import Observation
import QQBridgeKit

struct ChatJumpWindow {
  let floor: Int64?
  let count: Int
  let countFromTarget: Int
  let containsTarget: Bool
}

@MainActor
protocol ChatMessageJumpService {
  func prepare() async throws
  func window(for seq: Int64) throws -> ChatJumpWindow
  func loadOlder() async throws -> Int
}

@MainActor
struct SessionChatMessageJumpService: ChatMessageJumpService {
  let session: Session
  let chatId: Int64

  // 搜索结果可能来自首屏尚未拉完的页；判定缺失之前先等待会话差量追平。
  func prepare() async throws { try await session.sync.catchUpChat(chatId) }

  func window(for seq: Int64) throws -> ChatJumpWindow {
    let window = try session.store.historyTargetWindow(chatId: chatId, seq: seq)
    return ChatJumpWindow(floor: window.floor, count: window.count,
      countFromTarget: window.countFromTarget, containsTarget: window.containsTarget)
  }

  func loadOlder() async throws -> Int { try await session.sync.loadOlder(chatId, limit: 500) }
}

/// 所有定位入口共享一个任务；列表观察到目标后才滚动，旧任务不能收掉新任务的状态。
@MainActor @Observable
final class ChatMessageJump {
  struct Failure {
    let seq: Int64
    let message: String
  }

  private(set) var target: Int64?
  private(set) var failure: Failure?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Bool, Never>?
  @ObservationIgnored private var rendered: Set<Int64> = []
  @ObservationIgnored private var renderedLimit: Int?
  @ObservationIgnored private var waiter: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var timeout: Task<Void, Never>?
  @ObservationIgnored private let renderTimeout: Duration

  init(renderTimeout: Duration = .seconds(5)) { self.renderTimeout = renderTimeout }

  func updateRendered(_ seqs: Set<Int64>, limit: Int) {
    rendered = seqs
    renderedLimit = limit
    if let target, seqs.contains(target) { finishWaiting(true) }
  }

  @discardableResult
  func jump(to seq: Int64, delay: Duration = .zero, using service: any ChatMessageJumpService,
            history: ChatHistoryPagination, onFound: @escaping @MainActor (Int64) -> Void) async -> Bool {
    guard !Task.isCancelled, seq > 0 else { return false }
    cancel()
    let request = generation
    target = seq
    if !containsRendered(seq, history: history) { history.prepareForJump() }
    let running = Task { [weak self] in
      guard let self else { return false }
      defer {
        if generation == request { task = nil; target = nil; finishWaiting(false) }
      }
      do {
        if delay > .zero { try await Task.sleep(for: delay) }
        try check(request)
        if !containsRendered(seq, history: history) {
          history.prepareForJump()
          try await service.prepare()
          try check(request)
          var exhausted = false
          while true {
            try check(request)
            let window = try service.window(for: seq)
            if let floor = window.floor, seq >= floor {
              guard window.containsTarget else { throw JumpError.missing }
              history.reveal(through: window.countFromTarget + 20)
              while !containsRendered(seq, history: history) {
                guard await waitForRendered(seq, request: request, history: history) else {
                  try check(request)
                  throw JumpError.renderTimeout
                }
                try check(request)
              }
              break
            }
            if exhausted { throw JumpError.missing }
            let count = try await service.loadOlder()
            try check(request)
            let next = try service.window(for: seq)
            // 返回重叠页不能让窗口无限膨胀；按库里的连续区间大小展开。
            if let before = window.floor, next.floor == nil || (next.floor ?? before) > before {
              throw JumpError.windowChanged
            }
            if count > 0, next.floor == nil || next.floor == window.floor {
              throw JumpError.noProgress
            }
            history.recordLoadedWindow(next.count, exhausted: count == 0)
            exhausted = count == 0
          }
        }
        try check(request)
        onFound(seq)
        return true
      } catch {
        guard generation == request, !Task.isCancelled else { return false }
        failure = Failure(seq: seq, message: (error as? JumpError)?.message ?? LoadState.describe(error))
        return false
      }
    }
    task = running
    return await withTaskCancellationHandler {
      await running.value
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(request: request) }
    }
  }

  func dismissFailure() { failure = nil }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    target = nil
    failure = nil
    finishWaiting(false)
  }

  private func cancel(request: UUID) {
    guard generation == request else { return }
    cancel()
  }

  private func check(_ request: UUID) throws {
    guard generation == request else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func containsRendered(_ seq: Int64, history: ChatHistoryPagination) -> Bool {
    renderedLimit == history.limit && rendered.contains(seq)
  }

  private func waitForRendered(_ seq: Int64, request: UUID, history: ChatHistoryPagination) async -> Bool {
    if containsRendered(seq, history: history) { return true }
    return await withCheckedContinuation { continuation in
      waiter = continuation
      timeout = Task { [weak self, renderTimeout] in
        do { try await Task.sleep(for: renderTimeout) } catch { return }
        guard let self, generation == request else { return }
        finishWaiting(false)
      }
    }
  }

  private func finishWaiting(_ found: Bool) {
    timeout?.cancel()
    timeout = nil
    let continuation = waiter
    waiter = nil
    continuation?.resume(returning: found)
  }

  private enum JumpError: Error {
    case missing, noProgress, renderTimeout, windowChanged
    var message: String {
      switch self {
      case .missing: "这条消息已不存在或暂时不可用"
      case .noProgress: "历史记录暂时没有继续加载，请重试"
      case .renderTimeout: "消息列表更新超时，请重试"
      case .windowChanged: "历史记录范围已更新，请重试"
      }
    }
  }
}
