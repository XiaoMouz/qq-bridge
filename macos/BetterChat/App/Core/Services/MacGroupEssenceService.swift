import QQBridgeKit
import QQBridgeProto

@MainActor
protocol MacEssenceMediaWatch: AnyObject {
  func next() async -> Bool
  func cancel()
}

@MainActor
protocol MacGroupEssenceService {
  func load() async throws -> [Qqbridge_V1_GroupEssence]
  func watch(seqs: Set<Int64>) -> any MacEssenceMediaWatch
  func requestThumbnail(seq: Int64, ord: UInt32)
}

@MainActor
final class MacSessionGroupEssenceService: MacGroupEssenceService {
  private let session: Session
  private let groupID: Int64
  private let chatID: Int64
  private let requester = MediaRequester()

  init(session: Session, groupID: Int64, chatID: Int64) {
    self.session = session
    self.groupID = groupID
    self.chatID = chatID
  }

  func load() async throws -> [Qqbridge_V1_GroupEssence] {
    var request = Qqbridge_V1_ListGroupEssenceRequest()
    request.groupID = groupID
    return try await session.api.contacts.listGroupEssence(request: request, headers: session.api.headers).get().items
  }

  func watch(seqs: Set<Int64>) -> any MacEssenceMediaWatch {
    MacEssenceWatch(source: MediaReady.shared.watch(chatId: chatID, seqs: seqs))
  }

  func requestThumbnail(seq: Int64, ord: UInt32) {
    requester.want(chatId: chatID, seq: seq, ord: ord, session: session)
  }
}

@MainActor
final class MacEssenceWatch: MacEssenceMediaWatch {
  private let source: MediaReady.Watch
  private var cancelled = false
  init(source: MediaReady.Watch) { self.source = source }

  func next() async -> Bool {
    await withTaskCancellationHandler {
      // 超时继续等 Subscribe，不定时重拉群精华；手动刷新仍可作为恢复入口。
      while !cancelled && !Task.isCancelled {
        if await source.next() != nil { return !cancelled && !Task.isCancelled }
      }
      return false
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel() }
    }
  }

  func cancel() {
    cancelled = true
    source.cancel()
  }
}
