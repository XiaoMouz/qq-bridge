// 发送（docs/design.md 4.7"发送幂等"、6.2 Outbox）：
// - 每条消息在客户端生成 client_random_id，重试时保持不变，服务端据此去重，网络抖动重试不会发出两条；
// - 发出去之前先在本地发件箱里放一条"发送中"，聊天页立刻显示；服务端的发件箱条目随后经 pts 同步覆盖它
//   （发送中 → 已发送并对应到 QQ 的 seq，或失败及原因）。
// - 媒体先走秒传 / 断点续传上传（UploadService，下一步做），这里只管消息本身。
import Foundation
import QQBridgeProto

public final class Sender: Sendable {
  private let api: APIClient
  private let store: LocalStore

  public init(api: APIClient, store: LocalStore) {
    self.api = api
    self.store = store
  }

  /// 生成新的 client_random_id（正的 63 位随机数）。
  public static func newClientRandomId() -> Int64 {
    Int64.random(in: 1...Int64.max)
  }

  /// 发送一条消息。网络失败时按 1、2、4 秒重试三次（同一个 client_random_id）。
  @discardableResult
  public func send(
    chatId: Int64,
    segments: [Qqbridge_V1_OutgoingSegment],
    replyToSeq: Int64? = nil,
    clientRandomId: Int64 = Sender.newClientRandomId()
  ) async throws -> Qqbridge_V1_OutboxEntry {
    var pending = Qqbridge_V1_OutboxEntry()
    pending.clientRandomID = clientRandomId
    pending.chatID = chatId
    pending.state = .pending
    pending.segments = segments
    pending.createdAt = Int64(Date().timeIntervalSince1970)
    if let replyToSeq { pending.replyToSeq = replyToSeq }
    try store.upsertLocalOutbox(pending)

    var req = Qqbridge_V1_SendMessageRequest()
    req.chatID = chatId
    req.clientRandomID = clientRandomId
    req.segments = segments
    if let replyToSeq { req.replyToSeq = replyToSeq }

    var delay: Duration = .seconds(1)
    for attempt in 0...3 {
      do {
        let entry = try await api.messages.sendMessage(request: req, headers: api.headers).get().entry
        try store.upsertLocalOutbox(entry)
        return entry
      } catch let error as APIError where error.code == .unavailable || error.code == .deadlineExceeded || error.code == .unknown {
        if attempt == 3 { throw error }
        try await Task.sleep(for: delay)
        delay *= 2
      }
    }
    throw APIError(code: .unknown, message: "unreachable")
  }

  /// 纯文本消息。
  @discardableResult
  public func sendText(_ text: String, chatId: Int64, replyToSeq: Int64? = nil) async throws -> Qqbridge_V1_OutboxEntry {
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.text = text
    return try await send(chatId: chatId, segments: [seg], replyToSeq: replyToSeq)
  }
}

extension LocalStore {
  /// 本地先放进发件箱（不动全局 pts；服务端的条目随后经同步覆盖）。
  public func upsertLocalOutbox(_ entry: Qqbridge_V1_OutboxEntry) throws {
    try db.write { db in try Self.upsert(outbox: entry, db) }
  }
}
