import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BetterChat

/// 真正调用系统 NSItemProvider / CoreTransferable；不伪造 Finder 拖放会话。
@Suite(.serialized) @MainActor
struct MacDroppedProviderTests {
  private func source() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("provider-test-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("拖放测试.txt")
    try Data("只用于本机附件交付检查，不发送。\n".utf8).write(to: url)
    return url
  }

  private func load(_ provider: NSItemProvider) async throws -> DroppedItem {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadTransferable(type: DroppedItem.self) { result in
        continuation.resume(with: result)
      }
    }
  }

  @Test func contentsProviderPreservesTextFileBytes() async throws {
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let provider = try #require(NSItemProvider(contentsOf: url))
    print("FileDrop contents types: \(provider.registeredTypeIdentifiers)")
    let item = try await load(provider)
    defer { item.file?.discard() }
    #expect(item.failure == nil)
    let file = try #require(item.file)
    #expect(try Data(contentsOf: file.url) == Data(contentsOf: url))
    #expect(file.url.pathExtension == "txt")
  }

  @Test func fileURLProviderImportsTheReferencedFile() async throws {
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let provider = NSItemProvider(object: url as NSURL)
    print("FileDrop URL types: \(provider.registeredTypeIdentifiers)")
    let item = try await load(provider)
    defer { item.file?.discard() }
    #expect(item.failure == nil)
    let file = try #require(item.file)
    #expect(try Data(contentsOf: file.url) == Data(contentsOf: url))
    #expect(file.url.lastPathComponent == url.lastPathComponent)
  }

  @Test func contentOnlyProviderStillImportsAFile() async throws {
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let provider = NSItemProvider()
    provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { completion in
      completion(url, false, nil)
      return nil
    }
    let item = try await load(provider)
    defer { item.file?.discard() }
    #expect(item.failure == nil)
    let file = try #require(item.file)
    #expect(try Data(contentsOf: file.url) == Data(contentsOf: url))
  }

  @Test func URLRepresentationsRejectFoldersAndWebAddresses() async throws {
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    for unsupported in [url.deletingLastPathComponent(), URL(string: "https://example.invalid/test.txt")!] {
      let item = try await load(NSItemProvider(object: unsupported as NSURL))
      #expect(item.file == nil && item.failure != nil)
    }
  }
}
