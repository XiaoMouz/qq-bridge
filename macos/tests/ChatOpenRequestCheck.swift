import Foundation

@MainActor
private final class OpenGate {
  private var continuation: CheckedContinuation<Int64, any Error>?
  var waiting: Bool { continuation != nil }
  func wait() async throws -> Int64 {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func finish(_ id: Int64) {
    let pending = continuation
    continuation = nil
    pending?.resume(returning: id)
  }
}

@main
struct ChatOpenRequestCheck {
  enum Failure: Error { case offline }
  @MainActor static func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("等待条件未成立")
  }
  @MainActor static func main() async {
    let request = MacChatOpenRequest()
    var opened: [Int64] = []
    var failures = 0
    var firstReturned = false
    let first = OpenGate()
    request.start(peerKey: "first", operation: { let id = try await first.wait(); firstReturned = true; return id }, opened: { opened.append($0) }, failed: { _ in failures += 1 })
    await until { first.waiting }
    request.start(peerKey: "first", operation: { preconditionFailure("重复点击创建了请求") }, opened: { _ in }, failed: { _ in })

    // 模拟网络请求忽略取消、较晚返回：旧结果不能完成当前的选择。
    let second = OpenGate()
    request.start(peerKey: "second", operation: { try await second.wait() }, opened: { opened.append($0) }, failed: { _ in failures += 1 })
    await until { second.waiting }
    first.finish(1)
    await until { firstReturned }
    precondition(opened.isEmpty && request.peerKey == "second")
    second.finish(2)
    await until { request.peerKey == nil }
    precondition(opened == [2] && failures == 0)

    var abandonedReturned = false
    let abandoned = OpenGate()
    request.start(peerKey: "abandoned", operation: { let id = try await abandoned.wait(); abandonedReturned = true; return id }, opened: { opened.append($0) }, failed: { _ in failures += 1 })
    await until { abandoned.waiting }
    request.cancel()
    abandoned.finish(3)
    await until { abandonedReturned }
    precondition(request.peerKey == nil && opened == [2] && failures == 0)

    request.start(peerKey: "retry", operation: { throw Failure.offline }, opened: { opened.append($0) }, failed: { _ in failures += 1 })
    await until { request.peerKey == nil }
    precondition(failures == 1)
    request.start(peerKey: "retry", operation: { 4 }, opened: { opened.append($0) }, failed: { _ in failures += 1 })
    await until { request.peerKey == nil }
    precondition(opened == [2, 4] && failures == 1)

    request.start(peerKey: "cancelled", operation: { throw CancellationError() }, opened: { opened.append($0) }, failed: { _ in failures += 1 })
    await until { request.peerKey == nil }
    precondition(opened == [2, 4] && failures == 1)
    print("打开会话检查通过：重复点击、最后选择生效、退出后晚回包、失败重试、取消收尾")
  }
}
