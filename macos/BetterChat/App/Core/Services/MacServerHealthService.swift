import Foundation

/// 生产实现：只向用户填写的服务器发不带凭据的 GET /healthz，与 iOS LoginView 的检查一致。
@MainActor
struct MacHTTPServerReachabilityService: MacServerReachabilityService {
  /// 临时会话：不带 Cookie、缓存和凭据；请求与整体资源都限 5 秒，避免慢响应把「正在检查」拖住。
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    return URLSession(configuration: configuration)
  }()

  func resolve(_ input: String) -> URL? { AppModel.normalize(input) }

  func healthStatus(of server: URL) async throws -> Int? {
    var request = URLRequest(url: server.appending(path: "healthz"), timeoutInterval: 5)
    request.httpMethod = "GET"
    let (_, response) = try await Self.session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode
  }
}

extension MacServerPreset {
  /// 与 iOS LoginView 的预设菜单一致；Tailscale 地址只引用 LoginView 的常量，不复制。
  @MainActor static let standard = [
    MacServerPreset(title: "本机", address: "127.0.0.1:8080"),
    MacServerPreset(title: "Tailscale", address: LoginView.tailscale),
  ]
}
