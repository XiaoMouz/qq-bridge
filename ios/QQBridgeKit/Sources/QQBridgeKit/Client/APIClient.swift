// 与服务端通信（ConnectRPC，二进制 protobuf，经 Tailscale 的 HTTPS）。
// SyncAPI 是同步引擎用到的那部分接口：测试里换成假的服务端，界面层直接用 APIClient 的各个服务客户端。
import Connect
import Foundation
import QQBridgeProto

public struct ServerConfig: Sendable, Equatable, Codable {
  /// 例如 https://<mac>.<tailnet>.ts.net
  public var baseURL: URL
  public init(baseURL: URL) { self.baseURL = baseURL }
}

/// 同步引擎依赖的接口。
public protocol SyncAPI: Sendable {
  func getState() async throws -> Qqbridge_V1_GetStateResponse
  func getDifference(pts: Int64, limit: UInt32) async throws -> Qqbridge_V1_Difference
  func getChatDifference(chatId: Int64, chatPts: Int64, limit: UInt32) async throws -> Qqbridge_V1_GetChatDifferenceResponse
  func getChatDifferences(_ chats: [(chatId: Int64, chatPts: Int64)], perChatLimit: UInt32) async throws -> [Qqbridge_V1_ChatDifferenceResult]
  func getHistory(chatId: Int64, beforeSeq: Int64?, limit: UInt32) async throws -> Qqbridge_V1_GetHistoryResponse
  /// 先回放差量、再推实时更新；连接断开时以错误结束。
  func subscribe(pts: Int64) -> AsyncThrowingStream<Qqbridge_V1_SubscribeResponse, any Error>
}

public struct APIError: Error, Sendable, CustomStringConvertible {
  public let code: Code
  public let message: String
  public var description: String { "\(code): \(message)" }
  public var isUnauthenticated: Bool { code == .unauthenticated }
}

extension ResponseMessage {
  /// 取结果，失败时抛 APIError。
  public func get() throws -> Output {
    switch result {
    case .success(let output): return output
    case .failure(let error): throw APIError(code: error.code, message: error.message ?? "\(error.code)")
    }
  }
}

/// 一台已登录设备的客户端：持有设备令牌，所有请求自动带上。
public final class APIClient: SyncAPI {
  public let config: ServerConfig
  let token: String
  private let client: ProtocolClient

  public let auth: Qqbridge_V1_AuthServiceClient
  public let sync: Qqbridge_V1_SyncServiceClient
  public let dialogs: Qqbridge_V1_DialogServiceClient
  public let messages: Qqbridge_V1_MessageServiceClient
  public let media: Qqbridge_V1_MediaServiceClient
  public let contacts: Qqbridge_V1_ContactServiceClient
  public let calls: Qqbridge_V1_CallServiceClient
  public let admin: Qqbridge_V1_AdminServiceClient

  public init(config: ServerConfig, token: String, session: URLSessionConfiguration = .default) {
    self.config = config
    self.token = token
    // Subscribe 是长连接：不设整体超时，心跳由服务端每 25 秒发一次。
    let client = ProtocolClient(
      httpClient: URLSessionHTTPClient(configuration: session),
      config: ProtocolClientConfig(host: config.baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec())
    )
    self.client = client
    auth = .init(client: client)
    sync = .init(client: client)
    dialogs = .init(client: client)
    messages = .init(client: client)
    media = .init(client: client)
    contacts = .init(client: client)
    calls = .init(client: client)
    admin = .init(client: client)
  }

  /// 每个请求都要带的认证头。
  public var headers: Headers { ["authorization": ["Bearer \(token)"]] }

  /// QQ 表情资源（服务端 /qface/:id/:kind/:name，见 tools/qface-sync.py）：kind = png / apng / lottie。
  public func qfaceAsset(id: String, kind: String, name: String) async throws -> Data {
    var url = config.baseURL
    for part in ["qface", id, kind, name] { url.append(path: part) }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
    return data
  }

  /// 用账号密码登录，换一个设备令牌（之后存进钥匙串）。
  public static func login(
    config: ServerConfig,
    username: String,
    password: String,
    deviceName: String,
    platform: String = "ios"
  ) async throws -> Qqbridge_V1_LoginResponse {
    let client = ProtocolClient(
      httpClient: URLSessionHTTPClient(),
      config: ProtocolClientConfig(host: config.baseURL.absoluteString, networkProtocol: .connect, codec: ProtoCodec())
    )
    var req = Qqbridge_V1_LoginRequest()
    req.username = username
    req.password = password
    req.deviceName = deviceName
    req.platform = platform
    return try await Qqbridge_V1_AuthServiceClient(client: client).login(request: req, headers: [:]).get()
  }

  // MARK: SyncAPI

  public func getState() async throws -> Qqbridge_V1_GetStateResponse {
    try await sync.getState(request: .init(), headers: headers).get()
  }

  public func getDifference(pts: Int64, limit: UInt32) async throws -> Qqbridge_V1_Difference {
    var req = Qqbridge_V1_GetDifferenceRequest()
    req.pts = pts
    req.limit = limit
    return try await sync.getDifference(request: req, headers: headers).get().difference
  }

  public func getChatDifference(chatId: Int64, chatPts: Int64, limit: UInt32) async throws -> Qqbridge_V1_GetChatDifferenceResponse {
    var req = Qqbridge_V1_GetChatDifferenceRequest()
    req.chatID = chatId
    req.chatPts = chatPts
    req.limit = limit
    return try await sync.getChatDifference(request: req, headers: headers).get()
  }

  public func getChatDifferences(_ chats: [(chatId: Int64, chatPts: Int64)], perChatLimit: UInt32) async throws -> [Qqbridge_V1_ChatDifferenceResult] {
    var req = Qqbridge_V1_GetChatDifferencesRequest()
    req.chats = chats.map { c in
      var s = Qqbridge_V1_ChatSyncState()
      s.chatID = c.chatId
      s.chatPts = c.chatPts
      return s
    }
    req.perChatLimit = perChatLimit
    return try await sync.getChatDifferences(request: req, headers: headers).get().chats
  }

  public func getHistory(chatId: Int64, beforeSeq: Int64?, limit: UInt32) async throws -> Qqbridge_V1_GetHistoryResponse {
    var req = Qqbridge_V1_GetHistoryRequest()
    req.chatID = chatId
    if let beforeSeq { req.anchorSeq = beforeSeq }
    req.direction = .older
    req.limit = limit
    return try await messages.getHistory(request: req, headers: headers).get()
  }

  public func subscribe(pts: Int64) -> AsyncThrowingStream<Qqbridge_V1_SubscribeResponse, any Error> {
    let stream = sync.subscribe(headers: headers)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var req = Qqbridge_V1_SubscribeRequest()
          req.pts = pts
          try stream.send(req)
          for await result in stream.results() {
            switch result {
            case .message(let message):
              continuation.yield(message)
            case .complete(let code, let error, _):
              if code == .ok {
                continuation.finish()
              } else {
                let message = (error as? ConnectError)?.message ?? error.map { "\($0)" } ?? "\(code)"
                continuation.finish(throwing: APIError(code: code, message: message))
              }
              return
            case .headers:
              continue
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
        stream.cancel()
      }
    }
  }
}
