// 媒体缓存（docs/design.md 6.3）：本地只做有上限的缓存，服务端才是真相源。
// - 以 sha256 为键（缩略图、预览图、原件、可播放版本各有自己的 sha256），同一内容本地只存一份；
// - 上限（默认 2GB）与保留期（默认 7 天）：超期的先删，再按最久没用的删到上限以内；
// - 下载完按 sha256 校验，不对就丢弃；同一内容同时只下载一次；
// - 视频、长语音不必先下完：streamURL 给出签名链接，AVPlayer 边下边播（服务端支持 Range）。
import CryptoKit
import Foundation
import GRDB
import QQBridgeProto

/// 换签名下载链接（服务端 MediaService.SignMediaUrls）。
public protocol MediaURLSigner: Sendable {
  func sign(_ sha256: [String]) async throws -> [String: (url: URL, expiresAt: Date)]
}

/// 下载到临时文件。
public protocol MediaDownloader: Sendable {
  func download(_ url: URL) async throws -> URL
}

public struct URLSessionDownloader: MediaDownloader {
  let session: URLSession
  public init(session: URLSession = .shared) { self.session = session }
  public func download(_ url: URL) async throws -> URL {
    let (file, response) = try await session.download(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw MediaCacheError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    // 系统给的临时文件在回调返回后会被删，先挪走。
    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.moveItem(at: file, to: kept)
    return kept
  }
}

extension APIClient: MediaURLSigner {
  public func sign(_ sha256: [String]) async throws -> [String: (url: URL, expiresAt: Date)] {
    var req = Qqbridge_V1_SignMediaUrlsRequest()
    req.sha256 = sha256
    let res = try await media.signMediaUrls(request: req, headers: headers).get()
    var out: [String: (url: URL, expiresAt: Date)] = [:]
    for u in res.urls {
      // 服务端给的是相对路径（/media/...），拼上服务端地址。
      guard let url = URL(string: u.url, relativeTo: config.baseURL)?.absoluteURL else { continue }
      out[u.sha256] = (url, Date(timeIntervalSince1970: TimeInterval(u.expiresAt)))
    }
    return out
  }
}

public enum MediaCacheError: Error, Equatable {
  case notAvailable(String)
  case hashMismatch(String)
  case http(Int)
}

public struct MediaCacheLimits: Sendable, Equatable {
  /// nil = 不限。
  public var capBytes: Int64?
  /// nil = 永久。
  public var retentionDays: Int?
  public init(capBytes: Int64? = 2 * 1024 * 1024 * 1024, retentionDays: Int? = 7) {
    self.capBytes = capBytes
    self.retentionDays = retentionDays
  }
}

public struct MediaCacheUsage: Sendable, Equatable {
  public var totalBytes: Int64
  public var fileCount: Int
  /// 按会话（第一次缓存时所在的会话）。
  public var byChat: [Int64: Int64]
}

public actor MediaCache {
  private let directory: URL
  private let store: LocalStore
  private let signer: any MediaURLSigner
  private let downloader: any MediaDownloader
  private var limits: MediaCacheLimits
  private var inFlight: [String: Task<URL, any Error>] = [:]
  private var signed: [String: (url: URL, expiresAt: Date)] = [:]
  private let now: @Sendable () -> Date

  public init(
    directory: URL,
    store: LocalStore,
    signer: any MediaURLSigner,
    downloader: any MediaDownloader = URLSessionDownloader(),
    limits: MediaCacheLimits = MediaCacheLimits(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.directory = directory
    self.store = store
    self.signer = signer
    self.downloader = downloader
    self.limits = limits
    self.now = now
  }

  public func setLimits(_ limits: MediaCacheLimits) async throws {
    self.limits = limits
    try evict()
  }

  /// 本地文件：已缓存就直接返回，否则下载（同一内容并发请求只下一次）。
  public func file(for sha256: String, chatId: Int64? = nil) async throws -> URL {
    if let cached = try cachedFile(sha256) { return cached }
    if let running = inFlight[sha256] { return try await running.value }
    let task = Task { try await self.fetch(sha256, chatId: chatId) }
    inFlight[sha256] = task
    defer { inFlight[sha256] = nil }
    return try await task.value
  }

  /// 已缓存的文件（不触发下载），顺带记一次访问。
  public func cachedFile(_ sha256: String) throws -> URL? {
    let url = path(for: sha256)
    let known = try store.db.read { db in try Bool.fetchOne(db, sql: "select 1 from mediaCache where sha256 = ?", arguments: [sha256]) } ?? false
    guard known, FileManager.default.fileExists(atPath: url.path) else { return nil }
    try store.db.write { db in
      try db.execute(sql: "update mediaCache set lastAccessAt = ? where sha256 = ?", arguments: [Int64(now().timeIntervalSince1970), sha256])
    }
    return url
  }

  /// 这些里面手机上已经存着的（不算访问，不触发下载）。
  public func cachedSet(_ sha256s: [String]) throws -> Set<String> {
    guard !sha256s.isEmpty else { return [] }
    let known = try store.db.read { db in
      try String.fetchAll(db, sql: "select sha256 from mediaCache where sha256 in (\(sha256s.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(sha256s))
    }
    return Set(known.filter { FileManager.default.fileExists(atPath: path(for: $0).path) })
  }

  /// 删掉手机上的这几个文件（服务端的不动）。返回释放的字节数。
  @discardableResult
  public func remove(_ sha256s: [String]) throws -> Int64 {
    guard !sha256s.isEmpty else { return 0 }
    let victims = try store.db.read { db in
      try Row.fetchAll(db, sql: "select sha256, size from mediaCache where sha256 in (\(sha256s.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(sha256s))
        .map { ($0["sha256"] as String, $0["size"] as Int64) }
    }
    return try remove(victims)
  }

  /// 边下边播用的签名链接（不进缓存）。
  public func streamURL(for sha256: String) async throws -> URL {
    if let cached = try cachedFile(sha256) { return cached }
    return try await signedURL(sha256)
  }

  /// 预先换好一批签名链接（会话列表、聊天页滚动时批量调用，省得一个个换）。
  public func prepare(_ sha256s: [String]) async throws {
    let missing = sha256s.filter { s in signed[s].map { $0.expiresAt.timeIntervalSince(now()) < 60 } ?? true }
    guard !missing.isEmpty else { return }
    for (sha, value) in try await signer.sign(Array(Set(missing)).prefix(200).map { $0 }) { signed[sha] = value }
  }

  public func usage() throws -> MediaCacheUsage {
    try store.db.read { db in
      let total = try Int64.fetchOne(db, sql: "select coalesce(sum(size), 0) from mediaCache") ?? 0
      let count = try Int.fetchOne(db, sql: "select count(*) from mediaCache") ?? 0
      var byChat: [Int64: Int64] = [:]
      for row in try Row.fetchAll(db, sql: "select coalesce(chatId, 0) as chatId, sum(size) as size from mediaCache group by 1") {
        byChat[row["chatId"]] = row["size"]
      }
      return MediaCacheUsage(totalBytes: total, fileCount: count, byChat: byChat)
    }
  }

  /// 清掉某个会话缓存的媒体；chatId 为 nil 时全部清掉。返回释放的字节数。
  @discardableResult
  public func clear(chatId: Int64? = nil) throws -> Int64 {
    let victims = try store.db.read { db in
      try Row.fetchAll(
        db,
        sql: chatId == nil ? "select sha256, size from mediaCache" : "select sha256, size from mediaCache where chatId = ?",
        arguments: chatId.map { [$0] } ?? []
      ).map { ($0["sha256"] as String, $0["size"] as Int64) }
    }
    return try remove(victims)
  }

  /// 按保留期和上限清理（启动、后台任务、每次写入后调用）。返回释放的字节数。
  @discardableResult
  public func evict() throws -> Int64 {
    var freed: Int64 = 0
    if let days = limits.retentionDays {
      let cutoff = Int64(now().timeIntervalSince1970) - Int64(days) * 86400
      let old = try store.db.read { db in
        try Row.fetchAll(db, sql: "select sha256, size from mediaCache where lastAccessAt < ?", arguments: [cutoff])
          .map { ($0["sha256"] as String, $0["size"] as Int64) }
      }
      freed += try remove(old)
    }
    if let cap = limits.capBytes {
      let lru = try store.db.read { db in
        try Row.fetchAll(db, sql: "select sha256, size from mediaCache order by lastAccessAt").map { ($0["sha256"] as String, $0["size"] as Int64) }
      }
      var total = lru.reduce(0) { $0 + $1.1 }
      var victims: [(String, Int64)] = []
      for item in lru where total > cap {
        victims.append(item)
        total -= item.1
      }
      freed += try remove(victims)
    }
    return freed
  }

  // MARK: 内部

  private func fetch(_ sha256: String, chatId: Int64?) async throws -> URL {
    let url = try await signedURL(sha256)
    let tmp = try await downloader.download(url)
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard try Self.sha256(of: tmp) == sha256 else { throw MediaCacheError.hashMismatch(sha256) }
    let dest = path(for: sha256)
    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
    try FileManager.default.moveItem(at: tmp, to: dest)
    var excluded = dest
    var values = URLResourceValues()
    values.isExcludedFromBackup = true  // 缓存不进 iCloud 备份
    try? excluded.setResourceValues(values)
    let size = Int64((try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0)
    let ts = Int64(now().timeIntervalSince1970)
    try await store.db.write { db in
      try db.execute(
        sql: """
          insert into mediaCache (sha256, size, createdAt, lastAccessAt, chatId) values (?, ?, ?, ?, ?)
          on conflict(sha256) do update set size = excluded.size, lastAccessAt = excluded.lastAccessAt
          """,
        arguments: [sha256, size, ts, ts, chatId]
      )
    }
    try evict()
    return dest
  }

  private func signedURL(_ sha256: String) async throws -> URL {
    if let s = signed[sha256], s.expiresAt.timeIntervalSince(now()) > 60 { return s.url }
    let result = try await signer.sign([sha256])
    guard let s = result[sha256] else { throw MediaCacheError.notAvailable(sha256) }
    signed[sha256] = s
    return s.url
  }

  private func remove(_ items: [(String, Int64)]) throws -> Int64 {
    guard !items.isEmpty else { return 0 }
    var freed: Int64 = 0
    try store.db.write { db in
      for (sha, size) in items {
        try db.execute(sql: "delete from mediaCache where sha256 = ?", arguments: [sha])
        try? FileManager.default.removeItem(at: path(for: sha))
        freed += size
      }
    }
    return freed
  }

  nonisolated func path(for sha256: String) -> URL {
    let a = String(sha256.prefix(2))
    return directory.appendingPathComponent(a, isDirectory: true).appendingPathComponent(sha256)
  }

  static func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
