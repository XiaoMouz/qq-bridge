import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BetterChat

/// 只用新建的临时目录和构造的字节，不读用户缓存。
struct MacImageShareTests {
  private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xFF, 0xD9])
  // 两帧的 GIF89a 骨架：只比字节，原样拷贝就不会丢帧。
  private let gif = Data("GIF89a".utf8) + Data([0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
    0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00,
    0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00,
    0x3B])
  private let sha = String(repeating: "ab", count: 32)

  private func sandbox() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("betterchat-share-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
    return root
  }

  private func entries(_ directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()) ?? []
  }

  @Test func extensionlessImageExportsNamedCopyWithSameBytes() async throws {
    let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("cache/\(sha)")
    try jpeg.write(to: source)
    let out = root.appendingPathComponent("share")

    let shared = try await MacImageShareFile.export(source, sha256: sha, into: out)
    #expect(shared.lastPathComponent == "\(sha).jpg")
    #expect(try Data(contentsOf: shared) == jpeg)
    #expect(try Data(contentsOf: source) == jpeg)
    #expect(entries(root.appendingPathComponent("cache")) == [sha])

    // 重复分享同一张图复用副本，不越拷越多。
    let again = try await MacImageShareFile.export(source, sha256: sha, into: out)
    #expect(again == shared)
    #expect(entries(out) == ["\(sha).jpg"])
  }

  @Test func gifKeepsExtensionAndOriginalBytes() async throws {
    let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("cache/\(sha)")
    try gif.write(to: source)

    let shared = try await MacImageShareFile.export(source, sha256: sha, into: root.appendingPathComponent("share"))
    #expect(shared.pathExtension == "gif")
    #expect(try Data(contentsOf: shared) == gif)
  }

  @Test func transferableExportsImageFileBytes() async throws {
    let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
    // 走默认分享目录，用一个不会和真实缓存撞名的 sha，结束后删掉。
    let fakeSha = String(repeating: "0f", count: 32)
    let source = root.appendingPathComponent("cache/\(fakeSha)")
    try gif.write(to: source)
    defer { try? FileManager.default.removeItem(at: MacImageShareFile.defaultDirectory.appendingPathComponent("\(fakeSha).gif")) }

    let data = try await MacShareImage(sha256: fakeSha, source: source).exported(as: .image)
    #expect(data == gif)
  }

  @Test func rejectsInvalidSourcesWithoutLeftovers() async throws {
    let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    let cache = root.appendingPathComponent("cache")
    let real = cache.appendingPathComponent("real")
    try jpeg.write(to: real)
    let link = cache.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    let folder = cache.appendingPathComponent("folder")
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    let out = root.appendingPathComponent("share")

    for source in [cache.appendingPathComponent("missing"), link, folder] {
      await #expect(throws: MacImageShareFile.ShareError.self) {
        try await MacImageShareFile.export(source, sha256: sha, into: out)
      }
    }
    await #expect(throws: MacImageShareFile.ShareError.self) {
      try await MacImageShareFile.export(real, sha256: "../\(sha)", into: out)
    }
    #expect(entries(out).isEmpty)
  }

  @Test func copyFailureRemovesStagingFile() async throws {
    let root = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("cache/\(sha)")
    try jpeg.write(to: source)
    // 不可读的普通文件：通过类型检查，在拷贝时失败。
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
    let out = root.appendingPathComponent("share")

    await #expect(throws: (any Error).self) {
      try await MacImageShareFile.export(source, sha256: sha, into: out)
    }
    #expect(entries(out).isEmpty)
  }
}
