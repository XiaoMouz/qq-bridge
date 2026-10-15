import Foundation

@MainActor
private final class Gate {
  var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func finish() { continuation?.resume(); continuation = nil }
}

@main
struct AttachmentQueueCheck {
  enum Failure: Error { case upload }
  @MainActor static func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("附件任务未到达预期状态")
  }
  @MainActor static func main() async {
    var original: AttachmentQueue<String>? = AttachmentQueue()
    original!.items = ["first", "second"]
    let receiver = original!
    let gate = Gate()
    var runs = 0
    precondition(receiver.start {
      runs += 1
      let submitted = receiver.items
      await gate.wait()
      receiver.items.removeAll { submitted.contains($0) }
    })
    // start 返回前就占住队列，模拟同一事件循环里的两次点击。
    precondition(!receiver.start { preconditionFailure("重复批次执行") })
    await until { gate.continuation != nil }
    receiver.items.append("new draft")
    original = nil
    precondition(receiver.isSending)
    gate.finish()
    await until { !receiver.isSending }
    precondition(runs == 1 && receiver.items == ["new draft"])

    let failed = Gate()
    precondition(receiver.start {
      await failed.wait()
      throw Failure.upload
    })
    await until { failed.continuation != nil }
    let reopened = receiver
    failed.finish()
    await until { !reopened.isSending }
    precondition(reopened.error != nil && reopened.items == ["new draft"])
    precondition(reopened.start { reopened.items.removeAll() })
    precondition(reopened.error == nil)
    await until { !reopened.isSending }
    precondition(reopened.items.isEmpty)
    print("附件队列检查通过：同步防重、页面移交、后续草稿隔离、失败保留与重试")
  }
}
