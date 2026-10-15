import Foundation
import GRDB
import QQBridgeProto
import Testing

@testable import QQBridgeKit

private func interruptedEntry(_ id: Int64, state: Qqbridge_V1_OutboxState = .pending, pts: Int64 = 0) -> Qqbridge_V1_OutboxEntry {
  var entry = Qqbridge_V1_OutboxEntry()
  entry.clientRandomID = id
  entry.chatID = 153
  entry.state = state
  entry.pts = pts
  entry.createdAt = Int64(Date().timeIntervalSince1970)
  entry.replyToSeq = 42
  var text = Qqbridge_V1_OutgoingSegment()
  text.text = "仅本地磁盘恢复检查"
  var file = Qqbridge_V1_OutgoingSegment()
  file.file.sha256 = String(repeating: "a", count: 64)
  file.file.name = "恢复检查.txt"
  entry.segments = [text, file]
  return entry
}

private func seedRestartStore(_ container: URL, entries: [Qqbridge_V1_OutboxEntry]) throws {
  let store = try LocalStore.open(at: container.appendingPathComponent("Library/Application Support/qqbridge.sqlite"))
  for entry in entries { try store.upsertLocalOutbox(entry) }
}

private func reopen(_ container: URL, recovering: Bool) throws -> Session {
  try Session(config: ServerConfig(baseURL: URL(string: "https://restart.invalid")!),
              token: "isolated-test-placeholder", container: container, recoverInterruptedSends: recovering)
}

private struct RestartSendingAPI: MessageSendingAPI {
  let container: URL
  func sendMessage(_ request: Qqbridge_V1_SendMessageRequest) async throws -> Qqbridge_V1_OutboxEntry {
    // 辅助读取者在真正的 Sender 请求期间打开同一个磁盘库，不应把活跃请求改为失败。
    let reader = try reopen(container, recovering: false)
    let active = try #require(reader.store.outbox(chatId: 153).first)
    #expect(active.state == .pending)
    var acknowledged = active
    acknowledged.pts = 11
    return acknowledged
  }
}

struct SenderRestartTests {
  @Test func immediateRestartRecoversUnconfirmedSendWithoutLosingPayload() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: container) }
    let local = interruptedEntry(1)
    let pending = interruptedEntry(2, pts: 9)
    let failed = interruptedEntry(3, state: .failed, pts: 10)
    let sent = interruptedEntry(4, state: .sent, pts: 11)
    try seedRestartStore(container, entries: [local, pending, failed, sent])
    // 仅组装真实 Session，不启动同步，不读取钥匙串，不向测试地址发送任何请求。
    let restored = try Session(config: ServerConfig(baseURL: URL(string: "https://restart.invalid")!),
                               token: "isolated-test-placeholder", container: container, recoverInterruptedSends: true)
    let rows = Dictionary(uniqueKeysWithValues: try restored.store.outbox(chatId: 153).map { ($0.clientRandomID, $0) })
    let recovered = try #require(rows[1])
    #expect(recovered.state == .failed)
    #expect(!recovered.error.isEmpty)
    #expect(recovered.segments == local.segments)
    #expect(recovered.replyToSeq == local.replyToSeq)
    #expect(recovered.createdAt == local.createdAt)
    #expect(rows[2] == pending)
    #expect(rows[3] == failed)
    #expect(rows[4] == sent)
  }

  @Test func retryInterruptedAfterServerFailureIsRecoverableOnDisk() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-retry-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: container) }
    var retrying = interruptedEntry(7, state: .failed, pts: 10)
    try seedRestartStore(container, entries: [retrying])
    do {
      let session = try reopen(container, recovering: false)
      retrying.state = .pending
      // 模拟请求已经持久化，但进程未收到回包就退出；没有取消收尾步骤。
      try session.store.beginLocalOutboxAttempt(retrying)
    }
    let reader = try reopen(container, recovering: false)
    #expect(try reader.store.outbox(chatId: 153).first?.state == .pending)
    let restored = try reopen(container, recovering: true)
    let recovered = try #require(restored.store.outbox(chatId: 153).first)
    #expect(recovered.state == .failed)
    #expect(recovered.clientRandomID == retrying.clientRandomID)
    #expect(recovered.pts == 10)
    #expect(recovered.segments == retrying.segments)
    let secondRestore = try reopen(container, recovering: true)
    #expect(try secondRestore.store.outbox(chatId: 153).first == recovered)
  }

  @Test func acknowledgedRetryRemainsQueuedAfterRestart() async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-acked-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: container) }
    let failed = interruptedEntry(8, state: .failed, pts: 10)
    try seedRestartStore(container, entries: [failed])
    let session = try reopen(container, recovering: false)
    let sender = Sender(api: RestartSendingAPI(container: container), store: session.store)
    let acknowledged = try await sender.resend(failed)
    let restored = try reopen(container, recovering: true)
    #expect(try restored.store.outbox(chatId: 153).first == acknowledged)
    #expect(acknowledged.state == .pending)
    #expect(acknowledged.pts == 11)
  }

  @Test(arguments: [Qqbridge_V1_OutboxState.pending, .sending, .sent])
  func subscribedConfirmationClearsInterruptedAttempt(state: Qqbridge_V1_OutboxState) throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-subscribed-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: container) }
    let pending = interruptedEntry(11, pts: 10)
    try seedRestartStore(container, entries: [pending])
    do {
      let session = try reopen(container, recovering: false)
      try session.store.beginLocalOutboxAttempt(pending)
      try session.store.apply(outbox: interruptedEntry(11, state: state, pts: 11), pts: 11)
    }
    let restored = try reopen(container, recovering: true)
    let confirmed = try #require(restored.store.outbox(chatId: 153).first)
    #expect(confirmed.state == state)
    #expect(confirmed.pts == 11)
    #expect(confirmed.error.isEmpty)
  }

  @Test func migrationRecoversOldUnconfirmedEntriesAndPreservesConfirmedOnes() throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-v2-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: container) }
    let path = container.appendingPathComponent("Library/Application Support/qqbridge.sqlite")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let local = interruptedEntry(9)
    let confirmed = interruptedEntry(10, pts: 12)
    do {
      let legacy = try DatabaseQueue(path: path.path)
      try LocalStore.migrator.migrate(legacy, upTo: "v2-mediaIndex")
      try legacy.write { db in
        for entry in [local, confirmed] {
          try db.execute(sql: "insert into outbox (clientRandomId, chatId, state, createdAt, data) values (?, ?, ?, ?, ?)",
                         arguments: [entry.clientRandomID, entry.chatID, entry.state.rawValue, entry.createdAt, try entry.serializedData()])
        }
      }
    }
    let restored = try reopen(container, recovering: true)
    let entries = Dictionary(uniqueKeysWithValues: try restored.store.outbox(chatId: 153).map { ($0.clientRandomID, $0) })
    #expect(entries[9]?.state == .failed)
    #expect(entries[9]?.segments == local.segments)
    #expect(entries[10] == confirmed)
  }
}
