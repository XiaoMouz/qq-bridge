import Foundation

@MainActor
private final class Gate {
  private var continuation: CheckedContinuation<Void, any Error>?
  var waiting: Bool { continuation != nil }
  func wait() async throws {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func finish(_ error: (any Error)? = nil) {
    guard let continuation else { preconditionFailure("任务未到达等待点") }
    self.continuation = nil
    if let error { continuation.resume(throwing: error) }
    else { continuation.resume() }
  }
}

@main
struct ManualSyncCheck {
  enum Failure: Error { case offline }

  @MainActor
  static func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("异步状态未收尾")
  }

  @MainActor
  static func main() async {
    let sync = MacManualSync()
    var completed = 0
    let first = Gate()
    sync.start(operation: { try await first.wait() }, completed: { completed += 1 })
    await until { first.waiting }
    precondition(sync.isRunning)
    sync.start(operation: { preconditionFailure("重复入口启动了并发同步") }, completed: {})
    first.finish()
    await until { !sync.isRunning }
    precondition(completed == 1 && sync.error == nil)

    let failed = Gate()
    sync.start(operation: { try await failed.wait() }, completed: { preconditionFailure("失败被报为成功") })
    await until { failed.waiting }
    failed.finish(Failure.offline)
    await until { !sync.isRunning }
    precondition(sync.error != nil)

    // 取消后立即开始新任务，即便旧操作不合作、稍后才返回，也不能覆盖新任务状态。
    let old = Gate()
    sync.start(operation: { try await old.wait() }, completed: { preconditionFailure("已取消任务仍通知完成") })
    await until { old.waiting }
    precondition(sync.error == nil)
    sync.cancel()
    precondition(!sync.isRunning)
    let current = Gate()
    sync.start(operation: { try await current.wait() }, completed: { completed += 1 })
    await until { current.waiting }
    old.finish()
    for _ in 0..<100 { await Task.yield() }
    precondition(sync.isRunning && sync.error == nil && completed == 1)
    current.finish()
    await until { !sync.isRunning }
    precondition(completed == 2)

    sync.start(operation: { throw CancellationError() }, completed: { preconditionFailure("取消被报为成功") })
    await until { !sync.isRunning }
    precondition(sync.error == nil)
    print("手动同步检查通过：重复入口、成功、失败重试、取消、旧任务隔离")
  }
}
