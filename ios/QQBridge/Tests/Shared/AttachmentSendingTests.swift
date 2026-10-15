import Foundation
@testable import QQBridgeKit
import QQBridgeProto
import Testing
@testable import BetterChat

private enum AttachmentTestError: Error { case lostAcknowledgement, upload }

private actor AttachmentTestAPI: MessageSendingAPI {
  var loseFirstReply = false
  private(set) var requests: [Qqbridge_V1_SendMessageRequest] = []
  private(set) var deliveries: Set<Int64> = []
  init(loseFirstReply: Bool) { self.loseFirstReply = loseFirstReply }
  func sendMessage(_ request: Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry {
    requests.append(request)
    deliveries.insert(request.clientRandomID)
    if loseFirstReply {
      loseFirstReply = false
      throw AttachmentTestError.lostAcknowledgement
    }
    var entry = Qqbridge_V1_OutboxEntry()
    entry.clientRandomID = request.clientRandomID
    entry.chatID = request.chatID
    entry.segments = request.segments
    entry.replyToSeq = request.replyToSeq
    entry.state = .sent
    entry.pts = 1
    return entry
  }
}

@MainActor
private final class AttachmentTestService: AttachmentSendingService {
  let sender: Sender
  var uploads = 0
  var failUpload = false
  var progress: (@Sendable (Double) -> Void)?
  init(sender: Sender) { self.sender = sender }
  func prepare(_ payload: BetterChat.Attachment.Payload, progress: @escaping @Sendable (Double) -> Void) async throws -> Qqbridge_V1_OutgoingSegment {
    uploads += 1
    self.progress = progress
    if failUpload { throw AttachmentTestError.upload }
    var segment = Qqbridge_V1_OutgoingSegment()
    switch payload {
    case .image, .stored: segment.image.sha256 = "test-image"
    case .video: segment.video.sha256 = "test-video"
    case .file: segment.file.sha256 = "test-file"
    }
    return segment
  }
  func send(_ message: AttachmentMessage, chatId: Int64, clientRandomId: Int64) async throws {
    try await sender.send(chatId: chatId, segments: [message.segment], replyToSeq: message.replyToSeq, clientRandomId: clientRandomId)
  }
}

@MainActor
private final class ControlledAttachmentService: AttachmentSendingService {
  var progress: [@Sendable (Double) -> Void] = []
  var preparation: CheckedContinuation<Qqbridge_V1_OutgoingSegment, any Error>?
  var submission: CheckedContinuation<Void, any Error>?
  var sentIDs: [Int64] = []

  func prepare(_ payload: BetterChat.Attachment.Payload, progress: @escaping @Sendable (Double) -> Void) async throws -> Qqbridge_V1_OutgoingSegment {
    self.progress.append(progress)
    return try await withCheckedThrowingContinuation { preparation = $0 }
  }
  func send(_ message: AttachmentMessage, chatId: Int64, clientRandomId: Int64) async throws {
    sentIDs.append(clientRandomId)
    try await withCheckedThrowingContinuation { submission = $0 }
  }
  func finishUpload() {
    var segment = Qqbridge_V1_OutgoingSegment()
    segment.file.sha256 = "controlled-file"
    preparation?.resume(returning: segment)
    preparation = nil
  }
}

@Suite(.serialized)
@MainActor
struct AttachmentSendingTests {
  private func settled(_ condition: () -> Bool) async throws {
    for _ in 0..<2_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw AttachmentTestError.upload
  }

  @Test func oldUploadProgressCannotOverwriteRetryAfterDraftTransfer() async throws {
    let composer = Composer()
    let attachment = BetterChat.Attachment(payload: .file(URL(fileURLWithPath: "/nonexistent/test"), name: "test"), preview: nil)
    composer.attachments = [attachment]
    let service = ControlledAttachmentService()
    let first = Task { await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: composer, service: service) }
    try await settled { service.preparation != nil }
    service.preparation?.resume(throwing: AttachmentTestError.upload)
    service.preparation = nil
    _ = await first.value

    let transferred = composer.copyDraft()
    let retry = Task { await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: transferred, service: service) }
    try await settled { service.progress.count == 2 && service.preparation != nil }
    service.progress[1](0.25)
    try await settled { transferred.attachments.first?.state == .uploading(0.25) }
    service.progress[0](0.95)
    // 回调在 MainActor 任务中投递；让已排入的迟到进度有机会执行，再检查它没有写入。
    try await Task.sleep(for: .milliseconds(20))
    #expect(composer.attachments.first?.state == .uploading(0.25))
    #expect(transferred.attachments.first?.state == .uploading(0.25))
    service.finishUpload()
    try await settled { service.submission != nil }
    service.submission?.resume()
    service.submission = nil
    _ = await retry.value
    #expect(service.sentIDs == [attachment.clientRandomId])
    #expect(composer.attachments.isEmpty && transferred.attachments.isEmpty)
  }

  @Test func completedUploadAndPreparedRetryIgnoreRetainedProgress() async throws {
    let composer = Composer()
    let attachment = BetterChat.Attachment(payload: .file(URL(fileURLWithPath: "/nonexistent/test"), name: "test"), preview: nil)
    composer.attachments = [attachment]
    let service = ControlledAttachmentService()
    let first = Task { await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: composer, service: service) }
    try await settled { service.preparation != nil }
    service.finishUpload()
    try await settled { service.submission != nil }
    service.progress[0](0.3)
    try await Task.sleep(for: .milliseconds(20))
    #expect(composer.attachments.first?.state == .uploading(1))
    service.submission?.resume(throwing: AttachmentTestError.lostAcknowledgement)
    service.submission = nil
    _ = await first.value
    let retry = Task { await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: composer, service: service) }
    try await settled { service.submission != nil }
    #expect(service.progress.count == 1)
    service.progress[0](0.8)
    try await Task.sleep(for: .milliseconds(20))
    #expect(composer.attachments.first?.state == .uploading(1))
    service.submission?.resume()
    service.submission = nil
    _ = await retry.value
    #expect(service.sentIDs == [attachment.clientRandomId, attachment.clientRandomId])
    #expect(composer.attachments.isEmpty)
  }

  @Test func retainedUploadCallbackDoesNotKeepFailedDraftAlive() async throws {
    let service = ControlledAttachmentService()
    weak var released: Composer?
    do {
      let composer = Composer()
      released = composer
      let attachment = BetterChat.Attachment(payload: .image(Data([1])), preview: nil)
      composer.attachments = [attachment]
      let sending = Task { await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: composer, service: service) }
      try await settled { service.preparation != nil }
      service.preparation?.resume(throwing: AttachmentTestError.upload)
      service.preparation = nil
      _ = await sending.value
    }
    #expect(service.progress.count == 1)
    #expect(released == nil)
  }

  private func fixture(lostReply: Bool = false) throws -> (Composer, BetterChat.Attachment, AttachmentTestService, AttachmentTestAPI, LocalStore) {
    let api = AttachmentTestAPI(loseFirstReply: lostReply)
    let store = try LocalStore.inMemory()
    let service = AttachmentTestService(sender: Sender(api: api, store: store))
    let composer = Composer()
    let attachment = BetterChat.Attachment(payload: .image(Data([1, 2])), preview: nil)
    composer.attachments = [attachment]
    return (composer, attachment, service, api, store)
  }

  @Test func lostReplyRetriesSameMessageAcrossDraftTransfer() async throws {
    let (composer, attachment, service, api, store) = try fixture(lostReply: true)
    #expect(!(await AttachmentSending.send(attachment, chatId: 1, replyTo: 42, composer: composer, service: service)))
    let failed = try #require(composer.attachments.first)
    #expect(failed.preparedMessage?.replyToSeq == 42)
    let transferred = composer.copyDraft()
    #expect(!(await AttachmentSending.send(failed, chatId: 1, replyTo: 99, composer: transferred, service: service)))
    let requests = await api.requests
    #expect(requests.count == 2 && requests[0] == requests[1])
    #expect(await api.deliveries.count == 1)
    #expect(service.uploads == 1)
    #expect(transferred.attachments.isEmpty && composer.attachments.isEmpty)
    #expect(try store.outbox(chatId: 1).count == 1)
  }

  @Test func outboxRetryAndAttachmentRetryShareIdentity() async throws {
    let (composer, attachment, service, api, store) = try fixture(lostReply: true)
    _ = await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: composer, service: service)
    let entry = try #require(store.outbox(chatId: 1).first)
    try await service.sender.resend(entry)
    _ = await AttachmentSending.send(attachment, chatId: 1, replyTo: nil, composer: composer, service: service)
    #expect(await api.requests.count == 2)
    #expect(await api.deliveries == [attachment.clientRandomId])
    #expect(composer.attachments.isEmpty)
    #expect(service.uploads == 1)
  }

  @Test func uploadFailureKeepsReplyAndLateProgressCannotUndoFailure() async throws {
    let (composer, attachment, service, api, _) = try fixture()
    service.failUpload = true
    _ = await AttachmentSending.send(attachment, chatId: 1, replyTo: 42, composer: composer, service: service)
    service.progress?(0.8)
    for _ in 0..<10 { await Task.yield() }
    let failed = try #require(composer.attachments.first)
    if case .failed = failed.state {} else { Issue.record("迟到进度覆盖失败状态") }
    #expect(failed.replyToSeq == 42 && failed.preparedMessage == nil)
    #expect(await api.requests.isEmpty)
    service.failUpload = false
    #expect(!(await AttachmentSending.send(failed, chatId: 1, replyTo: 99, composer: composer, service: service)))
    #expect(await api.requests.first?.replyToSeq == 42)
    #expect(service.uploads == 2)
  }

  @Test(arguments: [false, true]) func fileAndVideoNeverConsumeReply(video: Bool) async throws {
    let (composer, _, service, api, _) = try fixture()
    let url = URL(fileURLWithPath: "/nonexistent/test")
    let attachment = BetterChat.Attachment(payload: video ? .video(url) : .file(url, name: "test"), preview: nil)
    composer.attachments = [attachment]
    #expect(!(await AttachmentSending.send(attachment, chatId: 1, replyTo: 42, composer: composer, service: service)))
    #expect(await api.requests.first?.replyToSeq == 0)
    #expect(composer.attachments.isEmpty)
  }

  @Test func identicalMediaChosenTwiceRemainSeparateMessages() async throws {
    let (composer, first, service, api, _) = try fixture()
    let second = BetterChat.Attachment(payload: first.payload, preview: nil)
    composer.attachments.append(second)
    _ = await AttachmentSending.send(first, chatId: 1, replyTo: nil, composer: composer, service: service)
    _ = await AttachmentSending.send(second, chatId: 1, replyTo: nil, composer: composer, service: service)
    #expect(await api.deliveries.count == 2)
    #expect(composer.attachments.isEmpty)
  }

  @Test func imageConsumesMatchingReplyAndRemovedAttachmentDoesNotSend() async throws {
    let (composer, attachment, service, api, _) = try fixture()
    #expect(await AttachmentSending.send(attachment, chatId: 1, replyTo: 42, composer: composer, service: service))
    #expect(!(await AttachmentSending.send(attachment, chatId: 1, replyTo: 42, composer: composer, service: service)))
    #expect(await api.requests.count == 1)
    #expect(service.uploads == 1)
  }
}
