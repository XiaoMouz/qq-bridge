// 会话装配：服务端地址 + 设备令牌 → APIClient、本地库、同步引擎、媒体缓存、发送器。
// App、通知扩展、分享扩展都用它；数据放在 App Group 容器里共用，令牌放在共享的钥匙串里。
import Foundation
import QQBridgeProto
import Security

/// 设备令牌的存放位置。
public protocol TokenStore: Sendable {
  func load() throws -> (config: ServerConfig, token: String)?
  func save(config: ServerConfig, token: String) throws
  func clear() throws
}

/// 钥匙串（accessGroup 设成 App Group 对应的钥匙串组，App 与扩展共用）。
public struct KeychainTokenStore: TokenStore {
  let service: String
  let accessGroup: String?

  public init(service: String = "qqbridge.device", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  private struct Stored: Codable {
    var config: ServerConfig
    var token: String
  }

  private var query: [String: Any] {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "default"]
    if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
    return q
  }

  public func load() throws -> (config: ServerConfig, token: String)? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: AnyObject?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
    let stored = try JSONDecoder().decode(Stored.self, from: data)
    return (stored.config, stored.token)
  }

  public func save(config: ServerConfig, token: String) throws {
    let data = try JSONEncoder().encode(Stored(config: config, token: token))
    SecItemDelete(query as CFDictionary)
    var q = query
    q[kSecValueData as String] = data
    // 解锁过一次之后通知扩展也能读（收到推送时设备可能是锁着的）。
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(q as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  public func clear() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
  }
}

public struct KeychainError: Error, CustomStringConvertible {
  public let status: OSStatus
  public var description: String { "keychain error \(status)" }
}

/// 内存里的令牌（测试、命令行工具用）。
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: (ServerConfig, String)?
  public init() {}
  public func load() throws -> (config: ServerConfig, token: String)? { lock.withLock { value.map { ($0.0, $0.1) } } }
  public func save(config: ServerConfig, token: String) throws { lock.withLock { value = (config, token) } }
  public func clear() throws { lock.withLock { value = nil } }
}

/// 一台已登录设备的全部部件。
public final class Session: Sendable {
  public let api: APIClient
  public let store: LocalStore
  public let sync: SyncEngine
  public let media: MediaCache
  public let sender: Sender

  /// container：App Group 容器目录（库放在 Library/Application Support，缓存放在 Library/Caches）。
  public init(config: ServerConfig, token: String, container: URL, cacheLimits: MediaCacheLimits = MediaCacheLimits()) throws {
    api = APIClient(config: config, token: token)
    store = try LocalStore.open(at: container.appendingPathComponent("Library/Application Support/qqbridge.sqlite"))
    sync = SyncEngine(api: api, store: store)
    media = MediaCache(
      directory: container.appendingPathComponent("Library/Caches/media", isDirectory: true),
      store: store,
      signer: api,
      limits: cacheLimits
    )
    sender = Sender(api: api, store: store)
    try? store.failStalePendingOutbox()
  }

  /// 登录并保存令牌。
  public static func login(
    config: ServerConfig,
    username: String,
    password: String,
    deviceName: String,
    tokens: any TokenStore,
    container: URL
  ) async throws -> Session {
    let res = try await APIClient.login(config: config, username: username, password: password, deviceName: deviceName)
    try tokens.save(config: config, token: res.token)
    return try Session(config: config, token: res.token, container: container)
  }

  /// 退出登录：服务端吊销令牌，清掉本地缓存和令牌。
  public func logout(tokens: any TokenStore) async {
    await sync.stop()
    _ = try? await api.auth.logout(request: .init(), headers: api.headers).get()
    try? store.reset()
    _ = try? await media.clear()
    try? tokens.clear()
  }
}
