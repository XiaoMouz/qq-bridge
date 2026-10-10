import Foundation
import QQBridgeProto
import Testing

@testable import QQBridgeKit

struct SenderTests {
  /// 服务端只接受 JS 安全整数范围内的 client_random_id，超出会拒收整条消息。
  @Test func clientRandomIdsStayWithinTheServersSafeIntegerRange() {
    for _ in 0..<10_000 {
      let id = Sender.newClientRandomId()
      #expect(id >= 1 && id <= 9_007_199_254_740_991)
    }
  }

  /// 上次没等到回应的本地条目启动时标成失败；服务端同步来的条目（带 pts）不动。
  @Test func staleLocalPendingEntriesBecomeFailedOnStart() throws {
    let store = try LocalStore.inMemory()
    let old = Int64(Date().timeIntervalSince1970) - 600
    func entry(_ id: Int64, pts: Int64, createdAt: Int64) -> Qqbridge_V1_OutboxEntry {
      var e = Qqbridge_V1_OutboxEntry()
      e.clientRandomID = id
      e.chatID = 1
      e.state = .pending
      e.pts = pts
      e.createdAt = createdAt
      return e
    }
    try store.upsertLocalOutbox(entry(1, pts: 0, createdAt: old))
    try store.upsertLocalOutbox(entry(2, pts: 9, createdAt: old))
    try store.upsertLocalOutbox(entry(3, pts: 0, createdAt: Int64(Date().timeIntervalSince1970)))
    try store.failStalePendingOutbox()
    let states = Dictionary(uniqueKeysWithValues: try store.outbox(chatId: 1).map { ($0.clientRandomID, $0.state) })
    #expect(states == [1: .failed, 2: .pending, 3: .pending])
    try store.deleteLocalOutbox(clientRandomId: 1)
    #expect(try store.outbox(chatId: 1).count == 2)
  }
}
