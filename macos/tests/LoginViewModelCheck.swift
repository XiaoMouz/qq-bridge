import Foundation

@MainActor
private final class Preferences: MacLoginPreferences {
  var server = "http://127.0.0.1:8080"
  var username = "tester"
  var saves = 0
  func save(server: String, username: String) {
    self.server = server
    self.username = username
    saves += 1
  }
}

@MainActor
private final class Authentication: MacAuthenticationService {
  var calls: [(String, String, String)] = []
  var pending: [CheckedContinuation<Void, any Error>] = []
  func signIn(server: String, username: String, password: String) async throws {
    calls.append((server, username, password))
    try await withCheckedThrowingContinuation { pending.append($0) }
  }
  func finish(_ error: (any Error)? = nil) {
    let continuation = pending.removeFirst()
    if let error { continuation.resume(throwing: error) }
    else { continuation.resume() }
  }
}

/// 不联网的健康检查替身：地址规则只做最小补全，请求挂起到检查代码手动结束。
@MainActor
private final class Reachability: MacServerReachabilityService {
  var requests: [URL] = []
  var pending: [(url: URL, continuation: CheckedContinuation<Int?, any Error>)] = []
  func resolve(_ input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(" ") else { return nil }
    return URL(string: text.contains("://") ? text : "http://" + text)
  }
  func healthStatus(of server: URL) async throws -> Int? {
    requests.append(server)
    return try await withCheckedThrowingContinuation { pending.append((server, $0)) }
  }
  func finish(_ url: String, status: Int? = 200, error: (any Error)? = nil) {
    let index = pending.firstIndex { $0.url.absoluteString == url }!
    let continuation = pending.remove(at: index).continuation
    if let error { continuation.resume(throwing: error) }
    else { continuation.resume(returning: status) }
  }
}

@main
struct LoginViewModelCheck {
  enum Failure: Error { case offline }
  @MainActor static func until(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("登录状态未收尾")
  }
  /// 防抖依赖真实时间，按时钟等待，超时视为失败。
  @MainActor static func wait(_ condition: () -> Bool, within limit: Duration = .seconds(3)) async {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    preconditionFailure("健康检查状态未在时限内到达")
  }
  @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(600)) }
  @MainActor static func main() async {
    let authentication = Authentication()
    let preferences = Preferences()
    let reachability = Reachability()
    let model = MacLoginViewModel(authentication: authentication, preferences: preferences, reachability: reachability)
    precondition(model.server == preferences.server && model.username == preferences.username)
    precondition(model.resolvedServer?.absoluteString == "http://127.0.0.1:8080" && model.health == .idle)
    model.submit()
    precondition(model.error != nil && !model.isSubmitting && authentication.calls.isEmpty)
    model.username = " tester "
    model.password = "test-only"
    model.submit()
    model.submit()
    await until { authentication.pending.count == 1 }
    precondition(authentication.calls.count == 1 && model.isSubmitting && model.error == nil)
    precondition(authentication.calls[0].1 == "tester")
    authentication.finish(Failure.offline)
    await until { !model.isSubmitting }
    precondition(model.error != nil && preferences.saves == 0)
    model.submit()
    await until { authentication.pending.count == 1 }
    authentication.finish()
    await until { !model.isSubmitting }
    precondition(model.error == nil && model.password.isEmpty && preferences.saves == 1)

    model.password = "old-test-only"
    model.submit()
    await until { authentication.pending.count == 1 }
    model.cancel()
    precondition(!model.isSubmitting && model.password.isEmpty)
    model.password = "new-test-only"
    model.submit()
    await until { authentication.pending.count == 2 }
    authentication.finish()
    for _ in 0..<100 { await Task.yield() }
    precondition(model.isSubmitting && preferences.saves == 1 && model.password == "new-test-only")
    authentication.finish()
    await until { !model.isSubmitting }
    precondition(preferences.saves == 2 && model.password.isEmpty)

    // 页面释放后，挂起的登录请求不能保活 ViewModel，也不能迟到保存偏好。
    var dismissed: MacLoginViewModel? = MacLoginViewModel(authentication: authentication, preferences: preferences, reachability: reachability)
    weak let released = dismissed
    dismissed?.password = "dismissed-test-only"
    dismissed?.submit()
    await until { authentication.pending.count == 1 }
    dismissed = nil
    precondition(released == nil)
    authentication.finish()
    for _ in 0..<100 { await Task.yield() }
    precondition(preferences.saves == 2)
    // 页面没出现过就不发健康请求。
    precondition(reachability.requests.isEmpty)
    await checkHealth(authentication: authentication, preferences: preferences, reachability: reachability)
    print("登录 ViewModel 检查通过：校验、防重、失败重试、成功清理、取消、旧请求隔离、页面释放，以及服务器地址补全、防抖、健康状态、重试与迟到结果隔离")
  }

  enum Offline: LocalizedError {
    case unreachable
    var errorDescription: String? { "测试替身：无法连接" }
  }

  @MainActor private static func checkHealth(authentication: Authentication, preferences: Preferences, reachability: Reachability) async {
    let presets = [MacServerPreset(title: "本机", address: "127.0.0.1:8080"), MacServerPreset(title: "远端", address: "remote.example")]
    let model = MacLoginViewModel(authentication: authentication, preferences: preferences, reachability: reachability, presets: presets)
    let saved = "http://127.0.0.1:8080"
    precondition(model.server == saved && model.presets == presets)

    // 页面出现时立即检查保存的地址，不等防抖。
    model.startHealthChecks()
    precondition(model.health == .checking && model.healthText == "正在检查…")
    await until { reachability.requests.count == 1 }
    precondition(reachability.requests[0].absoluteString == saved)

    // 连续输入：实际连接地址立即更新，防抖后只查最后一个地址；先前挂起的请求迟到也不覆盖。
    model.updateServer("a.example")
    precondition(model.resolvedServer?.absoluteString == "http://a.example" && model.resolvedServerText == "实际连接：http://a.example")
    model.updateServer("b.example")
    model.updateServer("c.example")
    precondition(model.resolvedServer?.absoluteString == "http://c.example" && model.health == .checking)
    await wait { reachability.requests.count == 2 }
    await settle()
    precondition(reachability.requests.map(\.absoluteString) == [saved, "http://c.example"])
    reachability.finish(saved, status: 200)
    for _ in 0..<100 { await Task.yield() }
    precondition(model.health == .checking)
    reachability.finish("http://c.example", status: 200)
    await until { model.health == .reachable }
    precondition(model.healthText == "✓ 服务器连得上" && !model.canRetryHealthCheck)

    // 非 200：能连上但不是本服务；重试立即重新请求同一地址。
    model.updateServer("d.example")
    await wait { reachability.pending.count == 1 }
    reachability.finish("http://d.example", status: 404)
    await until { model.health == .notServer(status: 404) }
    precondition(model.healthText?.contains("HTTP 404") == true && model.canRetryHealthCheck)
    model.retryHealthCheck()
    await until { reachability.pending.count == 1 }
    precondition(reachability.requests.last?.absoluteString == "http://d.example")
    reachability.finish("http://d.example", error: Offline.unreachable)
    await until { model.health == .failed("测试替身：无法连接") }
    precondition(model.healthText == "✗ 连不上：测试替身：无法连接" && model.canRetryHealthCheck)
    model.retryHealthCheck()
    await until { reachability.pending.count == 1 }
    reachability.finish("http://d.example", status: 200)
    await until { model.health == .reachable }

    // 地址不对：立即显示，不发请求；挂起中的旧请求被丢弃。
    model.updateServer("e.example")
    await wait { reachability.pending.count == 1 }
    let beforeInvalid = reachability.requests.count
    model.updateServer("bad address")
    precondition(model.resolvedServer == nil && model.resolvedServerText == "实际连接：地址不对" && model.health == .idle)
    precondition(model.healthText == nil && !model.canRetryHealthCheck)
    model.retryHealthCheck()
    await settle()
    precondition(reachability.requests.count == beforeInvalid)
    reachability.finish("http://e.example", status: 200)
    for _ in 0..<100 { await Task.yield() }
    precondition(model.health == .idle)

    // 预设：立即更新地址并检查，不等防抖。
    model.choosePreset(presets[1])
    precondition(model.server == "remote.example" && model.resolvedServer?.absoluteString == "http://remote.example")
    await until { reachability.pending.count == 1 }
    reachability.finish("http://remote.example", status: 500)
    await until { model.health == .notServer(status: 500) }

    // 离开页面：取消检查，迟到结果不回写；离开期间改地址不发请求，回来后立即查当前地址。
    model.retryHealthCheck()
    await until { reachability.pending.count == 1 }
    model.stopHealthChecks()
    precondition(model.health == .idle)
    reachability.finish("http://remote.example", status: 200)
    for _ in 0..<100 { await Task.yield() }
    precondition(model.health == .idle)
    let beforeHidden = reachability.requests.count
    model.updateServer("f.example")
    await settle()
    precondition(reachability.requests.count == beforeHidden && model.resolvedServer?.absoluteString == "http://f.example")
    model.startHealthChecks()
    await until { reachability.pending.count == 1 }
    precondition(reachability.requests.last?.absoluteString == "http://f.example")

    reachability.finish("http://f.example", status: 200)
    await until { model.health == .reachable }

    // 页面释放：挂起的健康请求不保活 ViewModel，迟到结果也无处回写。
    var dismissed: MacLoginViewModel? = MacLoginViewModel(authentication: authentication, preferences: preferences, reachability: reachability)
    weak let released = dismissed
    dismissed?.startHealthChecks()
    await until { reachability.pending.count == 1 }
    dismissed = nil
    precondition(released == nil)
    reachability.finish(saved, status: 200)
    for _ in 0..<100 { await Task.yield() }
  }
}
