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

  func add(_ data: Data) -> String {
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    lock.withLock { contents[sha] = data }
    return sha
  }

  func sign(_ sha256: [String]) async throws -> [String: (url: URL, expiresAt: Date)] {
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
}
