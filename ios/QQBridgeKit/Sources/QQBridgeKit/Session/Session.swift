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

public struct KeychainError: Error, LocalizedError, CustomStringConvertible {
  public let status: OSStatus
  public var description: String { "keychain error \(status)" }
  public var errorDescription: String? {
    if status == errSecMissingEntitlement {
      return "无法保存登录凭据：应用缺少钥匙串签名权限（\(status)）。请使用开发者签名版本。"
    }
    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
    return "钥匙串错误（\(status)）：\(reason)"
  }
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
  /// recoverInterruptedSends 仅供主 App 启动使用；扩展/辅助读取者打开同库时不能中止主 App 的发送。
  public init(config: ServerConfig, token: String, container: URL, cacheLimits: MediaCacheLimits = MediaCacheLimits(),
              recoverInterruptedSends: Bool = false) throws {
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
    if recoverInterruptedSends { try store.recoverInterruptedOutbox() }
  }

  /// 登录并保存令牌。
  public static func login(
    config: ServerConfig,
    username: String,
    password: String,
    deviceName: String,
    platform: String = "ios",
    recoverInterruptedSends: Bool = false,
    tokens: any TokenStore,
    container: URL
  ) async throws -> Session {
    let res = try await APIClient.login(config: config, username: username, password: password, deviceName: deviceName, platform: platform)
    try tokens.save(config: config, token: res.token)
    return try Session(config: config, token: res.token, container: container, recoverInterruptedSends: recoverInterruptedSends)
  }

  /// 退出登录：停同步、删本机令牌；clearCache 时再清掉本地库和媒体缓存，否则留给下次登录同一个 QQ 号接着用。
  /// 服务端吊销放到后台、最多等 10 秒：首次同步还没完成时连接被同步、预取、媒体下载占着，
  /// 以前要等这个请求返回才退出，界面一直卡着没反应。
  /// 返回吊销的任务：App 不用等；命令行工具退出前要等它，不然进程先结束了。
  @discardableResult
  public func logout(tokens: any TokenStore, clearCache: Bool = true) async -> Task<Void, Never> {
    await sync.stop()
    try? tokens.clear()
    let api = api
    let revoke = Task.detached { _ = try? await api.auth.logout(request: .init(), headers: api.headers).get() }
    Task.detached {
      try? await Task.sleep(for: .seconds(10))
      revoke.cancel()
    }
    if clearCache { await clearLocalData() }
    return revoke
  }

  /// 清掉本地库（会话、消息、发件箱等）和媒体缓存。
  public func clearLocalData() async {
    try? store.reset()
    try? store.forgetQqAccounts()
    _ = try? await media.clear()
  }

  /// 登录后、开始同步前调用：退出时保留的缓存如果属于别的 QQ 号（或别的服务端里同一个 id 对应了别的号），先清掉，
  /// 免得旧会话、旧消息混进新账号。问不到服务端时不动（马上开始的同步遇到对不上的游标会自己重置）。
  public func discardCacheOfOtherAccounts() async {
    guard let known = try? store.knownQqAccounts(), !known.isEmpty,
      let state = try? await api.getState()
    else { return }
    let remote = state.qqAccounts
    let sameIds = remote.allSatisfy { a in known[a.id].map { $0 == a.uin } ?? true }
    let overlap = remote.contains { known[$0.id] == $0.uin }
    if !sameIds || !overlap { await clearLocalData() }
  }
}
