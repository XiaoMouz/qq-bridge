// 媒体缓存（docs/design.md 6.3）：本地只做有上限的缓存，服务端才是真相源。
// - 以 sha256 为键（缩略图、预览图、原件、可播放版本各有自己的 sha256），同一内容本地只存一份；
// - 上限（默认 2GB）与保留期（默认 7 天）：超期的先删，再按最久没用的删到上限以内；
// - 下载完按 sha256 校验，不对就丢弃；同一内容同时只下载一次；
// - 视频、长语音不必先下完：streamURL 给出签名链接，AVPlayer 边下边播（服务端支持 Range）。
import CryptoKit
import Foundation
import GRDB
import Observation
import QQBridgeProto
import Synchronization

/// 换签名下载链接（服务端 MediaService.SignMediaUrls）。
public protocol MediaURLSigner: Sendable {
  func sign(_ sha256: [String]) async throws -> [String: (url: URL, expiresAt: Date)]
}

/// 下载到临时文件。
public protocol MediaDownloader: Sendable {
  func download(_ url: URL) async throws -> URL
  /// 边下边报进度（0...1）；不支持的实现退回不带进度的下载。
  func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension MediaDownloader {
  public func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    try await download(url)
  }
}

public struct URLSessionDownloader: MediaDownloader {
  let session: URLSession
  public init(session: URLSession = .shared) { self.session = session }

  public func download(_ url: URL) async throws -> URL {
    try await download(url) { _ in }
  }

  /// 2026-10-24 实测：传给 async 版 download(from:delegate:) 的任务代理收不到 didWriteData，
  /// 所以用 downloadTask 并观察它的 progress；每过 1% 报一次。
  public func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    // 弱网下大文件常在中途断：系统给了 resumeData 就从断点续（服务端回 ETag、支持 Range），
    // 不从头再下；连续断 3 次才算失败。
    var resumeData: Data?
    for attempt in 0... {
      do {
        return try await downloadOnce(url, resumeData: resumeData, progress: progress)
      } catch let error as URLError {
        guard attempt < 3, let data = error.downloadTaskResumeData, !Task.isCancelled else { throw error }
        resumeData = data
        try await Task.sleep(for: .milliseconds(500 << attempt))
      }
    }
    fatalError("unreachable")
  }

  private func downloadOnce(_ url: URL, resumeData: Data?, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let running = Mutex<(task: URLSessionDownloadTask, observation: NSKeyValueObservation)?>(nil)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { file, response, error in
          running.withLock { $0?.observation.invalidate() }
          if let error { continuation.resume(throwing: error); return }
          guard let file, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            continuation.resume(throwing: MediaCacheError.http((response as? HTTPURLResponse)?.statusCode ?? 0))
            return
          }
          // 系统给的临时文件在回调返回后会被删，先挪走。
          let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          do {
            try FileManager.default.moveItem(at: file, to: kept)
            continuation.resume(returning: kept)
          } catch {
            continuation.resume(throwing: error)
          }
        }
        let task = resumeData.map { session.downloadTask(withResumeData: $0, completionHandler: completion) }
          ?? session.downloadTask(with: url, completionHandler: completion)
        let last = Mutex(-1)
        let observation = task.progress.observe(\.fractionCompleted) { p, _ in
          let percent = Int(p.fractionCompleted * 100)
          if last.withLock({ old in defer { old = percent }; return old != percent }) { progress(Double(percent) / 100) }
        }
        running.withLock { $0 = (task, observation) }
        task.resume()
      }
    } onCancel: {
      running.withLock { $0?.task.cancel() }
    }
  }
}

/// 正在下载的媒体（按 sha256，0...1），界面直接观察：文件、原图按它画进度环。
@MainActor @Observable
public final class MediaTransfers {
  public private(set) var downloads: [String: Double] = [:]
  @ObservationIgnored private var active: [String: UUID] = [:]

  nonisolated public init() {}

  func begin(_ sha256: String, _ token: UUID) {
    active[sha256] = token
    downloads[sha256] = 0
  }

  /// 进度是从别的线程排队送来的：已经结束（或被新的一次下载替换）的不再记，免得停在「下载中」。
  func report(_ sha256: String, _ token: UUID, _ fraction: Double) {
    guard active[sha256] == token else { return }
    downloads[sha256] = fraction
  }

  func end(_ sha256: String, _ token: UUID) {
    guard active[sha256] == token else { return }
    active[sha256] = nil
    downloads[sha256] = nil
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
  /// 下载进度（界面观察）。
  public nonisolated let transfers = MediaTransfers()
  private let directory: URL
  private let store: LocalStore
  private let signer: any MediaURLSigner
  private let downloader: any MediaDownloader
  private var limits: MediaCacheLimits
  private var inFlight: [String: Task<URL, any Error>] = [:]
  private var signed: [String: (url: URL, expiresAt: Date)] = [:]
  private let now: @Sendable () -> Date
  /// 缓存总量的内存估计（nil = 还没统计）；下载后只在可能超上限时才真正清理。
  /// 2026-10-24：原来每下一个文件就把整张缓存表按访问时间排一遍，缓存越多越慢，还挡着同一 actor 里的其他图片请求。
  private var knownTotal: Int64?
  private var lastRetentionSweep = Date.distantPast
  /// 等着换签名链接的请求：短时间内的合成一次 SignMediaUrls。
  /// 2026-10-24：聊天页一屏的图片原来各自先换一次链接再下载，弱网下每张图都多等一个往返。
  private var pendingSigns: [String: [CheckedContinuation<(url: URL, expiresAt: Date)?, any Error>]] = [:]
  private var signFlush: Task<Void, Never>?

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
    let lastAccess = try store.db.read { db in
      try Int64.fetchOne(db, sql: "select lastAccessAt from mediaCache where sha256 = ?", arguments: [sha256])
    }
    guard let lastAccess, FileManager.default.fileExists(atPath: url.path) else { return nil }
    // 访问时间只用来按天清理和 LRU：一小时内记过就不再写，滚动聊天时每张图不再各写一次库。
    let ts = Int64(now().timeIntervalSince1970)
    if ts - lastAccess > 3600 {
      try store.db.write { db in
        try db.execute(sql: "update mediaCache set lastAccessAt = ? where sha256 = ?", arguments: [ts, sha256])
      }
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
    defer { knownTotal = try? totalBytes() }
    if let days = limits.retentionDays {
      lastRetentionSweep = now()
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
    let transfers = self.transfers
    let token = UUID()
    await transfers.begin(sha256, token)
    defer { Task { @MainActor in transfers.end(sha256, token) } }
    let tmp = try await downloader.download(url) { fraction in
      Task { @MainActor in transfers.report(sha256, token, fraction) }
    }
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
    if let total = knownTotal { knownTotal = total + size } else { knownTotal = try totalBytes() }
    let retentionDue = limits.retentionDays != nil && now().timeIntervalSince(lastRetentionSweep) > 3600
    let overCap = limits.capBytes.map { (knownTotal ?? 0) > $0 } ?? false
    if retentionDue || overCap { try evict() }
    return dest
  }

  private func totalBytes() throws -> Int64 {
    try store.db.read { db in try Int64.fetchOne(db, sql: "select coalesce(sum(size), 0) from mediaCache") ?? 0 }
  }

  private func signedURL(_ sha256: String) async throws -> URL {
    if let s = signed[sha256], s.expiresAt.timeIntervalSince(now()) > 60 { return s.url }
    let result = try await withCheckedThrowingContinuation { continuation in
      pendingSigns[sha256, default: []].append(continuation)
      if signFlush == nil {
        signFlush = Task {
          // 等一小会儿，让同一屏里其他图片的请求一起进来。
          try? await Task.sleep(for: .milliseconds(15))
          await self.flushSigns()
        }
      }
    }
    guard let s = result else { throw MediaCacheError.notAvailable(sha256) }
    return s.url
  }

  private func flushSigns() async {
    let batch = pendingSigns
    pendingSigns = [:]
    signFlush = nil
    let shas = Array(batch.keys)
    // 服务端一次最多签 200 个。
    for start in stride(from: 0, to: shas.count, by: 200) {
      let chunk = Array(shas[start..<min(start + 200, shas.count)])
      do {
        let result = try await signer.sign(chunk)
        for sha in chunk {
          if let value = result[sha] { signed[sha] = value }
          for waiter in batch[sha] ?? [] { waiter.resume(returning: result[sha]) }
        }
      } catch {
        for sha in chunk { for waiter in batch[sha] ?? [] { waiter.resume(throwing: error) } }
      }
    }
  }

  private func remove(_ items: [(String, Int64)]) throws -> Int64 {
    guard !items.isEmpty else { return 0 }
    var freed: Int64 = 0
    var removed: [String] = []
    var failure: (any Error)?
    for (sha, size) in items {
      do {
        try FileManager.default.removeItem(at: path(for: sha))
        removed.append(sha)
        freed += size
      } catch CocoaError.fileNoSuchFile {
        // 磁盘文件已不存在时只修复索引，不把它计入本次释放的空间。
        removed.append(sha)
      } catch {
        if failure == nil { failure = error }
      }
    }
    // 文件删除不能随数据库事务回滚；仅提交已成功删除的项，失败项保留供重试。
    try store.db.write { db in
      for sha in removed {
        try db.execute(sql: "delete from mediaCache where sha256 = ?", arguments: [sha])
      }
    }
    if let failure { throw failure }
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
