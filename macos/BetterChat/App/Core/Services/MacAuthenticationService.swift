import Foundation

@MainActor
protocol MacAuthenticationService {
  func signIn(server: String, username: String, password: String) async throws
}

/// 装配入口注入现有 AppModel 登录流程，页面不依赖全局单例或钥匙串细节。
@MainActor
struct MacSessionAuthenticationService: MacAuthenticationService {
  let authenticate: @MainActor (String, String, String) async throws -> Void

  func signIn(server: String, username: String, password: String) async throws {
    try await authenticate(server, username, password)
  }
}

@MainActor
protocol MacLoginPreferences {
  var server: String { get }
  var username: String { get }
  func save(server: String, username: String)
}

@MainActor
struct MacUserDefaultsLoginPreferences: MacLoginPreferences {
  let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  var server: String { defaults.string(forKey: "mac.server") ?? "" }
  var username: String { defaults.string(forKey: "mac.username") ?? "" }
  func save(server: String, username: String) {
    defaults.set(server, forKey: "mac.server")
    defaults.set(username, forKey: "mac.username")
  }
}

/// 登录页的服务器预设；具体地址在生产装配里给出，ViewModel 只按标题和地址展示。
struct MacServerPreset: Equatable, Sendable {
  let title: String
  let address: String
}

/// 登录前的服务器检查：地址补全规则与无认证的健康请求。
/// 生产实现直接复用 AppModel.normalize，ViewModel 不另写一套规则，也不直接发请求。
@MainActor
protocol MacServerReachabilityService {
  func resolve(_ input: String) -> URL?
  /// 请求 `<server>/healthz`，返回 HTTP 状态码；响应不是 HTTP 时返回 nil。
  func healthStatus(of server: URL) async throws -> Int?
}
