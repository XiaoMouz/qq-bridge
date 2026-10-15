import Foundation

@MainActor
private final class PermissionGate {
  var requests: [CheckedContinuation<Bool, Never>] = []
  func ask() async -> Bool { await withCheckedContinuation { requests.append($0) } }
  func answer(_ allowed: Bool, at index: Int = 0) { requests.remove(at: index).resume(returning: allowed) }
}

@main
struct VoiceRecordingStartCheck {
  @MainActor static func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("授权请求未到达预期状态")
  }
  @MainActor static func main() async throws {
    let gate = PermissionGate()
    let recorder = VoiceRecorder(requestPermission: { await gate.ask() })

    // 松手早于授权结果：即使随后授权成功，也不能访问麦克风。
    let released = Task { try await recorder.start() }
    await waitFor { gate.requests.count == 1 }
    precondition(recorder.finish() == nil)
    gate.answer(true)
    try await released.value
    precondition(!recorder.recording)

    // 旧请求返回拒绝时，新一轮请求仍在等授权，不得将旧错误带入新操作。
    let old = Task { try await recorder.start() }
    await waitFor { gate.requests.count == 1 }
    recorder.cancel()
    let current = Task { try await recorder.start() }
    await waitFor { gate.requests.count == 2 }
    gate.answer(false)
    try await old.value
    let duplicate = Task { try await recorder.start() }
    try await duplicate.value
    precondition(gate.requests.count == 1)
    gate.answer(false)
    do { try await current.value; preconditionFailure("有效请求的拒绝没有反馈") }
    catch { precondition(error as? VoiceRecorder.StartError == .denied) }

    // 页面退出会取消任务；授权系统不响应 Task.cancel，回调回来仍需自行隔离。
    let leaving = Task { try await recorder.start() }
    await waitFor { gate.requests.count == 1 }
    leaving.cancel()
    gate.answer(true)
    try await leaving.value
    precondition(!recorder.recording)

    let beforeStart = Task { try await recorder.start() }
    beforeStart.cancel()
    try await beforeStart.value
    precondition(gate.requests.isEmpty)

    // 取消后可以再次尝试，不能永久卡在“正在启动”。
    let retry = Task { try await recorder.start() }
    await waitFor { gate.requests.count == 1 }
    recorder.cancel()
    gate.answer(true)
    try await retry.value
    precondition(!recorder.recording)
    print("录音启动检查通过：提前松手、取消、迟到结果隔离、并发防重、拒绝反馈与重试；未访问麦克风")
  }
}
