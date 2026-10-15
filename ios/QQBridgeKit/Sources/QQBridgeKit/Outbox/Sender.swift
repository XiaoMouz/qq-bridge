// 发送（docs/design.md 4.7"发送幂等"、6.2 Outbox）：
// - 每条消息在客户端生成 client_random_id，重试时保持不变，服务端据此去重，网络抖动重试不会发出两条；
// - 发出去之前先在本地发件箱里放一条"发送中"，聊天页立刻显示；服务端的发件箱条目随后经 pts 同步覆盖它
//   （发送中 → 已发送并对应到 QQ 的 seq，或失败及原因）。
// - 媒体先走秒传 / 断点续传上传（UploadService，下一步做），这里只管消息本身。
import Foundation
import GRDB
import QQBridgeProto

public protocol MessageSendingAPI: Sendable {
  func sendMessage(_ request: Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry
}

extension APIClient: MessageSendingAPI {
  public func sendMessage(_ request: Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry {
    try await messages.sendMessage(request: request, headers: headers).get().entry
  }
}

public final class Sender: Sendable {
  private let api: any MessageSendingAPI
  private let store: LocalStore

  public init(api: any MessageSendingAPI, store: LocalStore) {
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
    if let existing = try store.outboxEntry(clientRandomId: clientRandomId) {
      // 附件条也会用原 ID 重试。保留首次发送时间与请求，不能用新草稿覆盖同一幂等键。
      guard existing.chatID == chatId, existing.segments == segments,
            existing.replyToSeq == (replyToSeq ?? 0) else {
        throw APIError(code: .invalidArgument, message: "发送标识已用于另一条消息")
      }
      if existing.state == .sent { return existing }
      if existing.pts > 0, existing.state == .pending || existing.state == .sending { return existing }
      return try await submit(existing)
    }
    var pending = Qqbridge_V1_OutboxEntry()
    pending.clientRandomID = clientRandomId
    pending.chatID = chatId
    pending.state = .pending
    pending.segments = segments
    pending.createdAt = Int64(Date().timeIntervalSince1970)
    if let replyToSeq { pending.replyToSeq = replyToSeq }
    return try await submit(pending)
  }

  private func submit(_ original: Qqbridge_V1_OutboxEntry) async throws -> Qqbridge_V1_OutboxEntry {
    try Task.checkCancellation()
    var pending = original
    pending.state = .pending
    pending.error = ""
    try store.beginLocalOutboxAttempt(pending)

    var req = Qqbridge_V1_SendMessageRequest()
    req.chatID = pending.chatID
    req.clientRandomID = pending.clientRandomID
    req.segments = pending.segments
    req.replyToSeq = pending.replyToSeq

    do {
      var delay: Duration = .seconds(1)
      for attempt in 0...3 {
        try Task.checkCancellation()
        do {
          let entry = try await api.sendMessage(req)
          // 成功回包即使在取消后到达也保留确认；不能把服务端已收下的消息当成未发送。
          try store.upsertLocalOutbox(entry)
          return entry
        } catch let error as APIError where attempt < 3 && (error.code == .unavailable || error.code == .deadlineExceeded || error.code == .unknown) {
          try await Task.sleep(for: delay)
          delay *= 2
        }
      }
      throw APIError(code: .unknown, message: "unreachable")
    } catch {
      // 包括退避等待期间取消；原来 sleep 的错误会绕过失败收尾，使本地条目一直转圈。
      // 未获确认不等于服务端未收到，因此重试仍必须沿用原来的幂等 ID。
      pending.state = .failed
      pending.error = error is CancellationError ? "发送已中止，可重试" : (error as? APIError)?.message ?? "\(error)"
      try? store.upsertLocalOutbox(pending)
      throw error
    }
  }

  /// 沿用 ID 重试：服务端已发送则返回原条目，明确失败则重新排队（outbox/service.ts）。
  /// 保留原条目及时间，既防止回包丢失后重复发送，也避免删除旧条目后再次失败丢失上下文。
  @discardableResult
  public func resend(_ entry: Qqbridge_V1_OutboxEntry) async throws -> Qqbridge_V1_OutboxEntry {
    try await submit(entry)
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
    try writeLocalOutbox(entry, beginsAttempt: false)
  }

  func beginLocalOutboxAttempt(_ entry: Qqbridge_V1_OutboxEntry) throws {
    try writeLocalOutbox(entry, beginsAttempt: true)
  }

  private func writeLocalOutbox(_ entry: Qqbridge_V1_OutboxEntry, beginsAttempt: Bool) throws {
    try db.write { db in
      // Subscribe 可能比发送 RPC 更早确认 sent；本地 pending/failed 或旧回包不能覆盖较新 pts。
      if let data = try Data.fetchOne(db, sql: "select data from outbox where clientRandomId = ?", arguments: [entry.clientRandomID]),
         try Qqbridge_V1_OutboxEntry(serializedBytes: data).pts > entry.pts { return }
      try Self.upsert(outbox: entry, db)
      if beginsAttempt {
        try db.execute(sql: "update outbox set localAttempt = 1 where clientRandomId = ?", arguments: [entry.clientRandomID])
      }
    }
  }

  /// 仅由主 App 的新会话启动调用，此时没有该会话的在途发送任务。
  /// 不依赖消息年龄：发送后一秒内重启也要可重试；旧版本 pts=0 的本地记录也可恢复。
  public func recoverInterruptedOutbox() throws {
    try db.write { db in
      let rows = try Row.fetchAll(db, sql: "select data, localAttempt from outbox where state = ?",
                                 arguments: [Qqbridge_V1_OutboxState.pending.rawValue])
      for row in rows {
        let data: Data = row["data"]
        let localAttempt: Bool = row["localAttempt"]
        var entry = try Qqbridge_V1_OutboxEntry(serializedBytes: data)
        guard localAttempt || entry.pts == 0 else { continue }
        entry.state = .failed
        entry.error = "上次发送未获确认，请重试"
        try Self.upsert(outbox: entry, db)
      }
    }
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
