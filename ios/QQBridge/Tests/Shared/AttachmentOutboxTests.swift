import Foundation
@testable import QQBridgeKit
import QQBridgeProto
import Testing
import SwiftUI
import UIKit
@testable import BetterChat

@MainActor
private final class DelayedAttachmentService: AttachmentSendingService {
  var reply: CheckedContinuation<Void, any Error>?
  func prepare(_ payload: BetterChat.Attachment.Payload, progress: @escaping @Sendable (Double) -> Void) async throws -> Qqbridge_V1_OutgoingSegment {
    var segment = Qqbridge_V1_OutgoingSegment()
    segment.image.sha256 = "test"
    return segment
  }
  func send(_ message: AttachmentMessage, chatId: Int64, clientRandomId: Int64) async throws {
    try await withCheckedThrowingContinuation { reply = $0 }
  }
}

@Suite(.serialized)
@MainActor
struct AttachmentOutboxTests {
  private func fixture() throws -> (LocalStore, Composer, BetterChat.Attachment) {
    let store = try LocalStore.inMemory()
    let composer = Composer()
    let attachment = BetterChat.Attachment(payload: .image(Data([1])), preview: nil)
    composer.attachments = [attachment]
    return (store, composer, attachment)
  }
  private func entry(_ attachment: BetterChat.Attachment, _ state: Qqbridge_V1_OutboxState) -> Qqbridge_V1_OutboxEntry {
    var result = Qqbridge_V1_OutboxEntry()
    result.clientRandomID = attachment.clientRandomId
    result.chatID = 1
    result.state = state
    result.error = state == .failed ? "测试发送失败" : ""
    return result
  }
  private func settled(_ condition: () -> Bool) async {
    for _ in 0..<2_000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("本地观察状态没有收尾")
  }

  @Test func liveOutboxTransitionsUpdateTrayAndResolveOnlyMatchingAttachment() async throws {
    let (store, composer, attachment) = try fixture()
    let untouched = BetterChat.Attachment(payload: .image(Data([2])), preview: nil)
    composer.attachments.append(untouched)
    composer.attachmentQueue.recordError("测试发送失败", sourceID: attachment.id)
    try store.upsertLocalOutbox(entry(attachment, .failed))
    let task = Task { await AttachmentSending.observe(store: store, chatId: 1, composer: composer) }
    defer { task.cancel() }
    await settled { composer.attachments.first?.state == .failed("测试发送失败") }
    try store.upsertLocalOutbox(entry(attachment, .pending))
    await settled { composer.attachments.first?.state == .queued }
    try store.upsertLocalOutbox(entry(attachment, .failed))
    await settled { composer.attachments.first?.state == .failed("测试发送失败") }
    try store.upsertLocalOutbox(entry(attachment, .sent))
    await settled { composer.attachments.map(\.id) == [untouched.id] }
    #expect(composer.attachmentQueue.error == nil)
  }

  @Test func returnAfterCancellationReadsMissedCompletionSnapshot() async throws {
    let (store, composer, attachment) = try fixture()
    try store.upsertLocalOutbox(entry(attachment, .failed))
    let first = Task { await AttachmentSending.observe(store: store, chatId: 1, composer: composer) }
    await settled { composer.attachments.first?.state == .failed("测试发送失败") }
    first.cancel()
    await first.value
    try store.upsertLocalOutbox(entry(attachment, .sent))
    #expect(composer.attachments.count == 1)
    let transferred = composer.copyDraft()
    let second = Task { await AttachmentSending.observe(store: store, chatId: 1, composer: transferred) }
    defer { second.cancel() }
    await settled { transferred.attachments.isEmpty }
    #expect(composer.attachments.isEmpty)
  }

  @Test func successfulAttachmentDoesNotDismissLaterTextError() throws {
    let (_, composer, attachment) = try fixture()
    composer.attachmentQueue.recordError("附件错误", sourceID: attachment.id)
    composer.attachmentQueue.error = "后续文字发送错误"
    AttachmentSending.reconcile([entry(attachment, .sent)], chatId: 1, composer: composer)
    #expect(composer.attachments.isEmpty)
    #expect(composer.attachmentQueue.error == "后续文字发送错误")
  }

  @Test func staleFailedSnapshotCannotOverrideActiveAttempt() async throws {
    let (store, composer, attachment) = try fixture()
    composer.update(attachment.id, .uploading(0.4))
    var finish: CheckedContinuation<Void, Never>?
    composer.attachmentQueue.start { await withCheckedContinuation { finish = $0 } }
    await settled { finish != nil }
    AttachmentSending.reconcile([entry(attachment, .failed)], chatId: 1, composer: composer)
    #expect(composer.attachments.first?.state == .uploading(0.4))
    finish?.resume()
    await settled { !composer.attachmentQueue.isSending }
    try store.upsertLocalOutbox(entry(attachment, .failed))
    let task = Task { await AttachmentSending.observe(store: store, chatId: 1, composer: composer) }
    defer { task.cancel() }
    await settled { composer.attachments.first?.state == .failed("测试发送失败") }
  }

  @Test func lateRPCFailureAfterConfirmationDoesNotResurrectError() async throws {
    let (_, composer, attachment) = try fixture()
    let service = DelayedAttachmentService()
    let sending = Task { await AttachmentSending.send(attachment, chatId: 1, replyTo: 42, composer: composer, service: service) }
    await settled { service.reply != nil }
    AttachmentSending.reconcile([entry(attachment, .sent)], chatId: 1, composer: composer)
    service.reply?.resume(throwing: CancellationError())
    #expect(await sending.value)
    #expect(composer.attachments.isEmpty)
    #expect(composer.attachmentQueue.error == nil)
  }

  @Test func absentRowsAndOtherChatsDoNotMeanSuccessfulSend() throws {
    let (_, composer, attachment) = try fixture()
    composer.update(attachment.id, .failed("保留"))
    var unrelated = entry(attachment, .sent)
    unrelated.chatID = 2
    AttachmentSending.reconcile([unrelated], chatId: 1, composer: composer)
    AttachmentSending.reconcile([], chatId: 1, composer: composer)
    #expect(composer.attachments.first?.state == .failed("保留"))
    AttachmentSending.reconcile([entry(attachment, .pending)], chatId: 1, composer: composer)
    #expect(composer.attachments.first?.state == .queued)
    AttachmentSending.reconcile([], chatId: 1, composer: composer)
    #expect(composer.attachments.first?.state == .failed("发送记录已不可用，可重试"))
  }

  @Test func swiftUIObserverRestartsForBatchCompletionAndNewAttachments() async throws {
    let (store, composer, attachment) = try fixture()
    try store.upsertLocalOutbox(entry(attachment, .failed))
    composer.update(attachment.id, .uploading(0.2))
    var finish: CheckedContinuation<Void, Never>?
    composer.attachmentQueue.start { await withCheckedContinuation { finish = $0 } }
    await settled { finish != nil }
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: Color.clear.modifier(AttachmentOutboxObserver(composer: composer, store: store, chatId: 1)))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    finish?.resume()
    await settled { composer.attachments.first?.state == .failed("测试发送失败") }

    // 新增附件时必须换观察集合；完成发生在新增前，也应由新订阅的首个快照处理。
    let added = BetterChat.Attachment(payload: .image(Data([2])), preview: nil)
    try store.upsertLocalOutbox(entry(added, .sent))
    composer.attachments.append(added)
    await settled { composer.attachments.map(\.id) == [attachment.id] }
    try store.upsertLocalOutbox(entry(attachment, .sent))
    await settled { composer.attachments.isEmpty }
  }
}
