import Foundation
import QQBridgeKit
import QQBridgeProto
import UniformTypeIdentifiers

struct AttachmentMessage {
  let segment: Qqbridge_V1_OutgoingSegment
  let replyToSeq: Int64?
}

@MainActor
protocol AttachmentSendingService {
  func prepare(_ payload: Attachment.Payload, progress: @escaping @Sendable (Double) -> Void) async throws -> Qqbridge_V1_OutgoingSegment
  func send(_ message: AttachmentMessage, chatId: Int64, clientRandomId: Int64) async throws
}

@MainActor
struct SessionAttachmentSendingService: AttachmentSendingService {
  let session: Session

  func prepare(_ payload: Attachment.Payload, progress: @escaping @Sendable (Double) -> Void) async throws -> Qqbridge_V1_OutgoingSegment {
    var segment = Qqbridge_V1_OutgoingSegment()
    switch payload {
    case .image(let data):
      let gif = data.starts(with: [0x47, 0x49, 0x46])
      let uploaded = try await session.api.upload(data, mime: gif ? "image/gif" : "image/jpeg", name: gif ? "image.gif" : "photo.jpg",
                                                  progress: progress)
      segment.image.sha256 = uploaded.sha256
    case .stored(let sha, let sticker):
      segment.image.sha256 = sha
      if sticker {
        segment.image.sticker = true
        segment.image.summary = "[动画表情]"
      }
    case .video(let url):
      let uploaded = try await session.api.uploadFile(at: url, mime: "video/mp4", name: url.lastPathComponent, progress: progress)
      segment.video.sha256 = uploaded.sha256
    case .file(let url, let name):
      let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      let uploaded = try await session.api.uploadFile(at: url, mime: mime, name: name, progress: progress)
      segment.file.sha256 = uploaded.sha256
      segment.file.name = name
    }
    return segment
  }

  func send(_ message: AttachmentMessage, chatId: Int64, clientRandomId: Int64) async throws {
    try await session.sender.send(chatId: chatId, segments: [message.segment],
      replyToSeq: message.replyToSeq, clientRandomId: clientRandomId)
  }
}

/// 草稿持有附件和发送标识，页面只发起动作；错误后保留同一请求供附件条重试。
@MainActor
enum AttachmentSending {
  static func observe(store: LocalStore, chatId: Int64, composer: Composer) async {
    let ids = composer.attachments.map(\.clientRandomId)
    guard !ids.isEmpty else { return }
    do {
      for try await entries in store.observeOutbox(chatId: chatId, clientRandomIds: ids) {
        guard !Task.isCancelled else { return }
        reconcile(entries, chatId: chatId, composer: composer)
      }
    } catch {
      // 观察失败不丢草稿；发送动作仍负责明确错误，重新进入页面时会重订阅。
    }
  }

  static func send(_ attachment: Attachment, chatId: Int64, replyTo: Int64?, composer: Composer,
                   service: any AttachmentSendingService) async -> Bool {
    guard let current = composer.attachments.first(where: { $0.id == attachment.id }) else { return false }
    composer.update(current.id, .uploading(current.preparedMessage == nil ? 0 : 1))
    let upload = AttachmentUploadProgress(composer: composer, id: current.id)
    defer { upload.finish() }
    let progress: @Sendable (Double) -> Void = { value in
      Task { @MainActor in upload.report(value) }
    }
    var submittedMessage = current.preparedMessage
    do {
      let message: AttachmentMessage
      if let prepared = current.preparedMessage { message = prepared }
      else {
        var reply = current.replyToSeq ?? replyTo
        switch current.payload {
        case .file, .video: reply = nil
        case .image, .stored: break
        }
        if let index = composer.attachments.firstIndex(where: { $0.id == current.id }) {
          composer.attachments[index].replyToSeq = reply
        }
        let segment = try await service.prepare(current.payload, progress: progress)
        upload.finish()
        composer.updateProgress(current.id, 1)
        message = AttachmentMessage(segment: segment, replyToSeq: reply)
        if let index = composer.attachments.firstIndex(where: { $0.id == current.id }) {
          composer.attachments[index].preparedMessage = message
        }
      }
      submittedMessage = message
      try await service.send(message, chatId: chatId, clientRandomId: current.clientRandomId)
      composer.attachments.removeAll { $0.id == current.id }
      // 重试可能带着旧引用；只有真正使用了本批次引用，后续附件/文字才应取消它。
      return replyTo != nil && message.replyToSeq == replyTo
    } catch {
      if current.delivery.confirmed {
        return replyTo != nil && submittedMessage?.replyToSeq == replyTo
      }
      // Subscribe 可能已经确认成功并移走附件；迟到的 RPC 错误不能重新弹失败提示。
      guard composer.attachments.contains(where: { $0.id == current.id }) else { return false }
      composer.update(current.id, .failed("\(error)"))
      composer.attachmentQueue.recordError(LoadState.describe(error), sourceID: current.id)
      return false
    }
  }

  static func reconcile(_ entries: [Qqbridge_V1_OutboxEntry], chatId: Int64, composer: Composer) {
    let states = Dictionary(entries.filter { $0.chatID == chatId }.map { ($0.clientRandomID, $0) }, uniquingKeysWith: { _, last in last })
    var resolved: Set<UUID> = []
    composer.attachments = composer.attachments.compactMap { attachment in
      guard let entry = states[attachment.clientRandomId] else {
        var updated = attachment
        if updated.state == .queued { updated.state = .failed("发送记录已不可用，可重试") }
        return updated
      }
      if entry.state == .sent {
        attachment.delivery.confirmed = true
        resolved.insert(attachment.id)
        return nil
      }
      // 当前批次的请求状态由发送动作控制，避免观察队列里较早的失败快照打断新尝试。
      guard !composer.attachmentQueue.isSending else { return attachment }
      var updated = attachment
      switch entry.state {
      case .pending, .sending:
        updated.state = .queued
        resolved.insert(attachment.id)
      case .failed: updated.state = .failed(entry.error.isEmpty ? "发送失败，可重试" : entry.error)
      default: break
      }
      return updated
    }
    composer.attachmentQueue.clearError(resolvedIDs: resolved)
  }
}

/// 一次上传结束后回调即失效，旧任务晚到的进度不能写入相同附件的新重试。
@MainActor
private final class AttachmentUploadProgress {
  private weak var composer: Composer?
  private let id: UUID

  init(composer: Composer, id: UUID) {
    self.composer = composer
    self.id = id
  }

  func report(_ value: Double) {
    guard value.isFinite else { return }
    composer?.updateProgress(id, min(1, max(0, value)))
  }

  func finish() { composer = nil }
}
