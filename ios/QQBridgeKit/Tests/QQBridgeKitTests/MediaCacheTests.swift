import CryptoKit
import Foundation
import Testing

@testable import QQBridgeKit

/// 假的签名与下载：内容按 sha256 预先放好，记录下载次数。
final class FakeMedia: MediaURLSigner, MediaDownloader, @unchecked Sendable {
  private let lock = NSLock()
  var contents: [String: Data] = [:]
  var corrupt: Set<String> = []
  private(set) var downloads: [String] = []
  private(set) var signCalls = 0

  func add(_ data: Data) -> String {
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    lock.withLock { contents[sha] = data }
    return sha
  }

  func sign(_ sha256: [String]) async throws -> [String: (url: URL, expiresAt: Date)] {
    lock.withLock { signCalls += 1 }
    var out: [String: (url: URL, expiresAt: Date)] = [:]
    for s in sha256 where lock.withLock({ contents[s] != nil }) {
      out[s] = (URL(string: "https://server.example/media/\(s)?sig=x")!, Date().addingTimeInterval(3600))
    }
    return out
  }

  func download(_ url: URL) async throws -> URL {
    let sha = url.lastPathComponent
    lock.withLock { downloads.append(sha) }
    try await Task.sleep(for: .milliseconds(20))
    var data = lock.withLock { contents[sha] } ?? Data()
    if lock.withLock({ corrupt.contains(sha) }) { data.append(0) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: file)
    return file
  }
}

/// 分几步报进度的下载（2026-10-24：验证进度从 MediaCache 传到界面观察的 MediaTransfers）。
final class SteppedMedia: MediaURLSigner, MediaDownloader, @unchecked Sendable {
  let base = FakeMedia()
  func sign(_ sha256: [String]) async throws -> [String: (url: URL, expiresAt: Date)] { try await base.sign(sha256) }
  func download(_ url: URL) async throws -> URL { try await base.download(url) }
  func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    for step in [0.25, 0.5, 0.75] {
      progress(step)
      try await Task.sleep(for: .milliseconds(150))
    }
    return try await base.download(url)
  }
}

final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { value } }
  func advance(days: Double) { lock.withLock { value = value.addingTimeInterval(days * 86400) } }
}

@Suite struct MediaCacheTests {
  func makeCache(_ media: FakeMedia, limits: MediaCacheLimits, clock: Clock = Clock()) throws -> (MediaCache, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-cache-\(UUID().uuidString)")
    let cache = MediaCache(directory: dir, store: try LocalStore.inMemory(), signer: media, downloader: media, limits: limits, now: { clock.now })
    return (cache, dir)
  }

  @Test func downloadsOnceVerifiesAndServesFromDisk() async throws {
    let media = FakeMedia()
    let sha = media.add(Data(repeating: 7, count: 1000))
    let (cache, dir) = try makeCache(media, limits: MediaCacheLimits())
    defer { try? FileManager.default.removeItem(at: dir) }

    async let a = cache.file(for: sha, chatId: 1)
    async let b = cache.file(for: sha, chatId: 1)
    let (fa, fb) = try await (a, b)
    #expect(fa == fb)
    #expect(media.downloads == [sha])  // 并发请求只下一次
    #expect(try Data(contentsOf: fa).count == 1000)
    _ = try await cache.file(for: sha)
    #expect(media.downloads.count == 1)

    let bad = media.add(Data(repeating: 9, count: 10))
    media.corrupt.insert(bad)
    await #expect(throws: MediaCacheError.hashMismatch(bad)) { try await cache.file(for: bad) }
    await #expect(throws: MediaCacheError.notAvailable("0000")) { try await cache.file(for: "0000") }
  }

  /// 一屏图片同时请求：只换一次签名链接（2026-10-24 合并签名），没有的照样报不可用。
  @Test func concurrentRequestsShareOneSigningRoundTrip() async throws {
    let media = FakeMedia()
    let shas = (0..<8).map { media.add(Data(repeating: UInt8($0), count: 100 + $0)) }
    let (cache, dir) = try makeCache(media, limits: MediaCacheLimits())
    defer { try? FileManager.default.removeItem(at: dir) }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for sha in shas { group.addTask { _ = try await cache.file(for: sha) } }
      group.addTask { await #expect(throws: MediaCacheError.notAvailable("ffff")) { try await cache.file(for: "ffff") } }
      try await group.waitForAll()
    }
    #expect(media.signCalls == 1)
    #expect(Set(media.downloads) == Set(shas))
  }

  /// 下载中进度出现在 MediaTransfers（界面按它画进度环），下完收起。
  @Test func reportsDownloadProgressToTransfersAndClearsWhenDone() async throws {
    let media = SteppedMedia()
    let sha = media.base.add(Data(repeating: 3, count: 4096))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = MediaCache(directory: dir, store: try LocalStore.inMemory(), signer: media, downloader: media,
                           limits: .init(capBytes: nil, retentionDays: nil))
    let transfers = cache.transfers
    let download = Task { try await cache.file(for: sha) }

    var seen: Set<Double> = []
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline, seen.count < 3 {
      if let p = await MainActor.run(body: { transfers.downloads[sha] }), p > 0 { seen.insert(p) }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(seen.isSuperset(of: [0.25, 0.5, 0.75]))
    _ = try await download.value
    var cleared = false
    for _ in 0..<50 where !cleared {
      cleared = await MainActor.run(body: { transfers.downloads[sha] == nil })
      if !cleared { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(cleared)
  }

  @Test func evictsExpiredThenLeastRecentlyUsedToStayUnderTheCap() async throws {
    let media = FakeMedia()
    let clock = Clock()
    let (cache, dir) = try makeCache(media, limits: MediaCacheLimits(capBytes: 2500, retentionDays: 7), clock: clock)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = media.add(Data(repeating: 1, count: 1000))
    let b = media.add(Data(repeating: 2, count: 1000))
    let c = media.add(Data(repeating: 3, count: 1000))
    _ = try await cache.file(for: a, chatId: 1)
    clock.advance(days: 1)
    _ = try await cache.file(for: b, chatId: 2)
    clock.advance(days: 1)
    _ = try await cache.cachedFile(a)  // a 刚用过
    _ = try await cache.file(for: c, chatId: 2)  // 超过 2500：最久没用的 b 被清掉
    #expect(try await cache.cachedFile(b) == nil)
    #expect(try await cache.usage() == MediaCacheUsage(totalBytes: 2000, fileCount: 2, byChat: [1: 1000, 2: 1000]))

    clock.advance(days: 8)  // 超过保留期
    #expect(try await cache.evict() == 2000)
    #expect(try await cache.usage().fileCount == 0)
  }

  @Test func clearsOneChat() async throws {
    let media = FakeMedia()
    let (cache, dir) = try makeCache(media, limits: MediaCacheLimits(capBytes: nil, retentionDays: nil))
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = media.add(Data(repeating: 1, count: 10))
    let b = media.add(Data(repeating: 2, count: 20))
    _ = try await cache.file(for: a, chatId: 1)
    _ = try await cache.file(for: b, chatId: 2)
    #expect(try await cache.clear(chatId: 2) == 20)
    #expect(try await cache.cachedFile(a) != nil)
    #expect(try await cache.cachedFile(b) == nil)
  }

  @Test func clearKeepsExportedDownloads() async throws {
    let media = FakeMedia()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-clear-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MediaCache(directory: root.appendingPathComponent("Cache"), store: try LocalStore.inMemory(),
                           signer: media, downloader: media, limits: .init(capBytes: nil, retentionDays: nil))
    let content = Data("已导出的文件应独立于缓存".utf8)
    let sha = media.add(content)
    let cached = try await cache.file(for: sha, chatId: 153)
    let downloads = root.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let exported = downloads.appendingPathComponent("检查.txt")
    try FileManager.default.copyItem(at: cached, to: exported)

    #expect(try await cache.clear() == Int64(content.count))
    #expect(try await cache.usage().fileCount == 0)
    #expect(!FileManager.default.fileExists(atPath: cached.path))
    #expect(try Data(contentsOf: exported) == content)
  }

  @Test func clearRetainsFailedFilesAndCommitsSuccessfulRemovals() async throws {
    let media = FakeMedia()
    let (cache, dir) = try makeCache(media, limits: .init(capBytes: nil, retentionDays: nil))
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = media.add(Data(repeating: 1, count: 10))
    let b = media.add(Data(repeating: 2, count: 20))
    let allowed = try await cache.file(for: a, chatId: 153)
    let protected = try await cache.file(for: b, chatId: 153)
    let parent = protected.deletingLastPathComponent()
    #expect(allowed.deletingLastPathComponent() != parent)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

    await #expect(throws: (any Error).self) { try await cache.clear() }
    #expect(!FileManager.default.fileExists(atPath: allowed.path))
    #expect(FileManager.default.fileExists(atPath: protected.path))
    #expect(try await cache.cachedFile(a) == nil)
    #expect(try await cache.cachedFile(b) == protected)
    #expect(try await cache.usage() == MediaCacheUsage(totalBytes: 20, fileCount: 1, byChat: [153: 20]))

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    #expect(try await cache.clear() == 20)
    #expect(try await cache.usage().fileCount == 0)
  }

  @Test func clearRepairsMissingFileWithoutClaimingFreedBytes() async throws {
    let media = FakeMedia()
    let (cache, dir) = try makeCache(media, limits: .init(capBytes: nil, retentionDays: nil))
    defer { try? FileManager.default.removeItem(at: dir) }
    let sha = media.add(Data(repeating: 3, count: 20))
    let cached = try await cache.file(for: sha)
    try FileManager.default.removeItem(at: cached)
    #expect(try await cache.clear() == 0)
    #expect(try await cache.usage().fileCount == 0)
  }
}
