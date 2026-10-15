import Foundation
import Observation

/// 登录前对服务器的健康检查结果；只描述最近一次地址的状态。
enum MacServerHealth: Equatable {
  case idle
  case checking
  case reachable
  /// 连得上但 /healthz 不是 200（或不是 HTTP 响应），多半填成了别的服务。
  case notServer(status: Int?)
  case failed(String)
}

@MainActor
@Observable
final class MacLoginViewModel {
  private(set) var server: String
  var username: String
  var password = ""
  private(set) var isSubmitting = false
  private(set) var error: String?
  /// 补全协议、去掉结尾斜杠之后真正会连接的地址；填得不对时为 nil。
  private(set) var resolvedServer: URL?
  private(set) var health = MacServerHealth.idle
  let presets: [MacServerPreset]
  @ObservationIgnored private let authentication: any MacAuthenticationService
  @ObservationIgnored private let preferences: any MacLoginPreferences
  @ObservationIgnored private let reachability: any MacServerReachabilityService
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private let describeError: (any Error) -> String
  @ObservationIgnored private var request: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var healthCheck: Task<Void, Never>?
  @ObservationIgnored private var healthGeneration = UUID()
  /// 页面可见时才发健康请求；离开页面后迟到的结果一律丢弃。
  @ObservationIgnored private var isCheckingHealth = false

  init(
    authentication: any MacAuthenticationService,
    preferences: any MacLoginPreferences,
    reachability: any MacServerReachabilityService,
    presets: [MacServerPreset] = [],
    debounce: Duration = .milliseconds(400),
    describeError: @escaping (any Error) -> String = { $0.localizedDescription }
  ) {
    self.authentication = authentication
    self.preferences = preferences
    self.reachability = reachability
    self.presets = presets
    self.debounce = debounce
    self.describeError = describeError
    server = preferences.server
    username = preferences.username
    resolvedServer = reachability.resolve(preferences.server)
  }

  deinit {
    request?.cancel()
    healthCheck?.cancel()
  }

  var resolvedServerText: String { "实际连接：\(resolvedServer?.absoluteString ?? "地址不对")" }

  var healthText: String? {
    switch health {
    case .idle: nil
    case .checking: "正在检查…"
    case .reachable: "✓ 服务器连得上"
    case .notServer(let status):
      "✗ 地址能连上，但不是 BetterChat 的服务器" + (status.map { "（HTTP \($0)）" } ?? "")
    case .failed(let message): "✗ 连不上：\(message)"
    }
  }

  var canRetryHealthCheck: Bool {
    switch health {
    case .notServer, .failed: resolvedServer != nil
    case .idle, .checking, .reachable: false
    }
  }

  /// 输入框每次变化都调用：立即更新实际连接地址，健康检查防抖后只查最后一个地址。
  func updateServer(_ text: String) {
    guard text != server else { return }
    server = text
    resolvedServer = reachability.resolve(text)
    scheduleHealthCheck(after: debounce)
  }

  /// 选预设是明确的一次选择，不需要等输入停下。
  func choosePreset(_ preset: MacServerPreset) {
    guard preset.address != server else { return }
    server = preset.address
    resolvedServer = reachability.resolve(preset.address)
    scheduleHealthCheck(after: .zero)
  }

  func startHealthChecks() {
    guard !isCheckingHealth else { return }
    isCheckingHealth = true
    scheduleHealthCheck(after: .zero)
  }

  func stopHealthChecks() {
    isCheckingHealth = false
    invalidateHealthCheck()
    health = .idle
  }

  func retryHealthCheck() {
    scheduleHealthCheck(after: .zero)
  }

  func submit() {
    guard !isSubmitting else { return }
    let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = password
    guard !address.isEmpty, !name.isEmpty, !secret.isEmpty else {
      error = "请填写服务器地址、用户名和密码。"
      return
    }
    error = nil
    isSubmitting = true
    let id = UUID()
    generation = id
    request = Task { [weak self, authentication] in
      do {
        try await authentication.signIn(server: address, username: name, password: secret)
        guard let self, self.generation == id, !Task.isCancelled else { return }
        self.preferences.save(server: address, username: name)
        self.password = ""
        self.isSubmitting = false
        self.request = nil
      } catch {
        guard let self, self.generation == id, !Task.isCancelled else { return }
        self.error = error is CancellationError ? nil : self.describeError(error)
        self.isSubmitting = false
        self.request = nil
      }
    }
  }

  func cancel() {
    stopHealthChecks()
    generation = UUID()
    request?.cancel()
    request = nil
    isSubmitting = false
    password = ""
    error = nil
  }

  private func invalidateHealthCheck() {
    healthGeneration = UUID()
    healthCheck?.cancel()
    healthCheck = nil
  }

  /// 每次换地址都换一代并取消上一个请求；旧请求即使不响应取消、迟到返回，也因代号不符被丢弃。
  private func scheduleHealthCheck(after delay: Duration) {
    invalidateHealthCheck()
    guard isCheckingHealth, let url = resolvedServer else {
      if isCheckingHealth { health = .idle }
      return
    }
    health = .checking
    let id = healthGeneration
    healthCheck = Task { [weak self, reachability] in
      if delay > .zero {
        do { try await Task.sleep(for: delay) } catch { return }
      }
      guard !Task.isCancelled, self?.healthGeneration == id else { return }
      let outcome: MacServerHealth
      do {
        let status = try await reachability.healthStatus(of: url)
        outcome = status == 200 ? .reachable : .notServer(status: status)
      } catch {
        outcome = .failed(error.localizedDescription)
      }
      guard let self, self.healthGeneration == id, !Task.isCancelled else { return }
      self.health = outcome
      self.healthCheck = nil
    }
  }
}
