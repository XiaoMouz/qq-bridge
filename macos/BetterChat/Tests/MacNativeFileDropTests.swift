import Foundation
import Testing
import UIKit
@testable import BetterChat

@Suite(.serialized) @MainActor
struct MacNativeFileDropTests {
  private func source() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-drop-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("拖放测试.txt")
    try Data("本地预览测试，不发送".utf8).write(to: url)
    return url
  }

  private func discard(_ attachments: [BetterChat.Attachment]) {
    for attachment in attachments {
      if case .file(let url, _) = attachment.payload {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
    }
  }

  @Test func actualChatCollectionRetainsItsNativeDropDelegate() throws {
    let controller = ChatCollectionController()
    controller.loadViewIfNeeded()
    let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
    #expect(collection.dropDelegate === controller.fileDropReceiver)
    let provider = NSItemProvider(object: URL(fileURLWithPath: "/tmp/test.txt") as NSURL)
    #expect(!controller.fileDropReceiver.canHandle([provider]))
    var received: [NSItemProvider] = []
    controller.fileDropReceiver.onDrop = { received = $0 }
    #expect(controller.fileDropReceiver.canHandle([provider]))
    #expect(!controller.fileDropReceiver.canHandle([]))
    controller.fileDropReceiver.receive([provider])
    #expect(received.count == 1 && received.first === provider)
  }

  @Test func mixedProvidersPreserveValidFilesAndReportFailures() async throws {
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let providers = [NSItemProvider(object: url as NSURL), NSItemProvider(),
                     NSItemProvider(object: url.deletingLastPathComponent() as NSURL)]
    let result = await DroppedProviders.load(providers)
    defer { discard(result.attachments) }
    #expect(result.attachments.count == 1)
    #expect(result.failures.count == 2)
    let attachment = try #require(result.attachments.first)
    guard case .file(let copy, let name) = attachment.payload else {
      Issue.record("TXT 没有进入文件预览"); return
    }
    #expect(name == url.lastPathComponent)
    #expect(copy != url)
    #expect(try Data(contentsOf: copy) == Data(contentsOf: url))
    #expect(attachment.state == .ready)
  }

  @Test func dropStaysWithOriginalDraftAndDoesNotSend() async throws {
    let url = try source()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let original = AttachmentQueue<BetterChat.Attachment>()
    var current = original
    let receiver = ChatFileDropReceiver()
    receiver.onDrop = { DroppedProviders.enqueue($0, into: current) }
    receiver.receive([NSItemProvider(object: url as NSURL)])
    #expect(original.pendingImports == 1)
    current = AttachmentQueue<BetterChat.Attachment>()
    await withCheckedContinuation { continuation in
      original.enqueueImport({ .init() }) { _ in continuation.resume() }
    }
    defer { discard(original.items) }
    #expect(original.items.count == 1)
    #expect(original.items.first?.state == .ready)
    #expect(!original.isSending && original.pendingImports == 0)
    #expect(current.items.isEmpty && current.pendingImports == 0)
  }
}
