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

  /// 服务端把 int8 当 JS number 处理，只接受 2^53 - 1 以内的值。
  public static let maxClientRandomId: Int64 = (1 << 53) - 1

  /// 生成新的 client_random_id（1 到 2^53 - 1 的随机数）。
  public static func newClientRandomId() -> Int64 {
    Int64.random(in: 1...maxClientRandomId)
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
      } catch let error as APIError where attempt < 3 && (error.code == .unavailable || error.code == .deadlineExceeded || error.code == .unknown) {
        try await Task.sleep(for: delay)
        delay *= 2
      } catch {
        // 服务端没收下：本地标成失败（红色感叹号），可以长按重发或删除，不会一直转圈。
        pending.state = .failed
        pending.error = (error as? APIError)?.message ?? "\(error)"
        try? store.upsertLocalOutbox(pending)
        throw error
      }
    }
    throw APIError(code: .unknown, message: "unreachable")
  }

  /// 重发一条失败的消息：换新的 client_random_id（旧的服务端可能根本没收下），删掉旧条目。
  @discardableResult
  public func resend(_ entry: Qqbridge_V1_OutboxEntry) async throws -> Qqbridge_V1_OutboxEntry {
    try store.deleteLocalOutbox(clientRandomId: entry.clientRandomID)
    return try await send(chatId: entry.chatID, segments: entry.segments, replyToSeq: entry.replyToSeq > 0 ? entry.replyToSeq : nil)
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

  /// 启动时：上次没等到服务端回应就退出的"发送中"条目标成失败，可以长按重发。
  /// 服务端收下的条目带 pts（经同步而来），不受影响。
  public func failStalePendingOutbox(olderThan seconds: Int64 = 120) throws {
    let cutoff = Int64(Date().timeIntervalSince1970) - seconds
    try db.write { db in
      let stale = try Data.fetchAll(
        db,
        sql: "select data from outbox where state = ? and createdAt < ?",
        arguments: [Qqbridge_V1_OutboxState.pending.rawValue, cutoff]
      ).map { try Qqbridge_V1_OutboxEntry(serializedBytes: $0) }
      for var entry in stale where entry.pts == 0 {
        entry.state = .failed
        entry.error = "没有发出去"
        try Self.upsert(outbox: entry, db)
      }
    }
  }

  /// 删掉本地发件箱里的一条（只用于服务端没收下的失败消息）。
  public func deleteLocalOutbox(clientRandomId: Int64) throws {
    try db.write { db in try db.execute(sql: "delete from outbox where clientRandomId = ?", arguments: [clientRandomId]) }
  }
}
