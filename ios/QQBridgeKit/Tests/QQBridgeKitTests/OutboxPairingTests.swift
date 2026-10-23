import Foundation
import QQBridgeProto
import Testing

@testable import QQBridgeKit

/// 发件箱条目和同步来的消息对上之后才收起（2026-10-23：重复显示、发出后消失一阵）。
struct OutboxPairingTests {
  private let me: Int64 = 1114096791

  private func entry(_ id: Int64, _ text: String, state: Qqbridge_V1_OutboxState, seq: Int64 = 0, at: Int64 = 1000) -> Qqbridge_V1_OutboxEntry {
    var e = Qqbridge_V1_OutboxEntry()
    e.clientRandomID = id
    e.chatID = 1
    e.state = state
    e.seq = seq
    e.createdAt = at
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.text = text
    e.segments = [seg]
    return e
  }

  private func message(_ seq: Int64, _ text: String, from sender: Int64? = nil, at: Int64 = 1001) -> Qqbridge_V1_Message {
    var m = Qqbridge_V1_Message()
    m.chatID = 1
    m.seq = seq
    m.senderID = sender ?? me
    m.time = at
    var seg = Qqbridge_V1_Segment()
    seg.text.text = text
    m.segments = [seg]
    return m
  }

  /// 已发送但消息还没同步到：继续占位，不能消失。
  @Test func sentEntryStaysUntilItsMessageArrives() {
    let e = entry(1, "你好", state: .sent, seq: 50)
    #expect(LocalStore.pairOutbox([e], messages: [], presentSeqs: [], selfUin: me).map(\.clientRandomID) == [1])
    #expect(LocalStore.pairOutbox([e], messages: [message(50, "你好")], presentSeqs: [50], selfUin: me).isEmpty)
  }

  /// 消息先到、发件箱还是发送中：收起发送中，只留实心的那条。
  @Test func pendingEntryHidesWhenTheSameMessageArrivesFirst() {
    let e = entry(1, "你好 ", state: .sending)
    #expect(LocalStore.pairOutbox([e], messages: [message(50, "你好")], presentSeqs: [], selfUin: me).isEmpty)
    // 别人发的同样内容、比发送早的旧消息都不算。
    #expect(LocalStore.pairOutbox([e], messages: [message(50, "你好", from: 42)], presentSeqs: [], selfUin: me).count == 1)
    #expect(LocalStore.pairOutbox([e], messages: [message(50, "你好", at: 900)], presentSeqs: [], selfUin: me).count == 1)
  }

  /// 连发两条一样的：一条消息只抵一条发件箱条目。
  @Test func identicalMessagesPairOneToOne() {
    let a = entry(1, "1", state: .sending, at: 1000)
    let b = entry(2, "1", state: .pending, at: 1001)
    let shown = LocalStore.pairOutbox([a, b], messages: [message(50, "1", at: 1001)], presentSeqs: [], selfUin: me)
    #expect(shown.map(\.clientRandomID) == [2])
  }

  /// 已发送条目认领的 seq 不再给别的条目用。
  @Test func claimedSeqIsNotReused() {
    let sent = entry(1, "1", state: .sent, seq: 50, at: 1000)
    let next = entry(2, "1", state: .sending, at: 1000)
    let shown = LocalStore.pairOutbox([sent, next], messages: [message(50, "1")], presentSeqs: [50], selfUin: me)
    #expect(shown.map(\.clientRandomID) == [2])
  }

  /// @ 后面的空格、拆成几段的文字不影响；回复引用段不算内容。
  @Test func signatureIgnoresWhitespaceAndReplySegment() {
    var at = Qqbridge_V1_OutgoingSegment()
    at.mentionUserID = 42
    var text = Qqbridge_V1_OutgoingSegment()
    text.text = " 看这个"
    var reply = Qqbridge_V1_Segment()
    reply.reply.seq = 7
    var mention = Qqbridge_V1_Segment()
    mention.mention.userID = 42
    mention.mention.name = "某人"
    var t1 = Qqbridge_V1_Segment()
    t1.text.text = " 看"
    var t2 = Qqbridge_V1_Segment()
    t2.text.text = "这个"
    #expect(OutboxSignature.of([at, text]) == OutboxSignature.of([reply, mention, t1, t2]))
  }
}
