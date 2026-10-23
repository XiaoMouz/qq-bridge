// 给界面用的观察接口：本地库一变，界面跟着刷新（GRDB ValueObservation）。
// 同步引擎只管往库里写，界面只管观察库，两边不直接打交道。
import Foundation
import GRDB
import QQBridgeProto

/// 会话列表里的一行：会话 + 对方资料（名字、头像）。
public struct DialogItem: Sendable, Identifiable, Equatable {
  public var dialog: Qqbridge_V1_Dialog
  public var peer: Qqbridge_V1_Peer?
  public var id: Int64 { dialog.chatID }

  /// 显示名：备注 > 昵称 / 群名 > 号码。
  public var title: String {
    if let p = peer {
      if !p.remark.isEmpty { return p.remark }
      if !p.name.isEmpty { return p.name }
    }
    return String(dialog.peerID)
  }

  public var isGroup: Bool { dialog.scene == .group }
  /// 收进群助手的群。
  public var isArchived: Bool { dialog.notifyPolicy == "archived" }
  /// 接收但不提醒（含收进群助手、免打扰）。
  public var isMuted: Bool { ["muted", "archived"].contains(dialog.notifyPolicy) }
}

/// 聊天页里的一项：消息、服务事件（灰条），或者还在发件箱里的消息。
public enum ChatItem: Sendable, Identifiable, Equatable {
  case message(Qqbridge_V1_Message)
  case event(Qqbridge_V1_ChatEvent)
  case outgoing(Qqbridge_V1_OutboxEntry)

  public var id: String {
    switch self {
    case .message(let m): "m\(m.seq)"
    case .event(let e): "e\(e.id)"
    case .outgoing(let o): "o\(o.clientRandomID)"
    }
  }

  /// 排序用的时间（秒）。
  public var time: Int64 {
    switch self {
    case .message(let m): m.time
    case .event(let e): e.time
    case .outgoing(let o): o.createdAt
    }
  }
}

extension LocalStore {
  /// 附件条需要已发送终态，不能以聊天列表里消失（也可能被删除）代替发送确认。
  public func observeOutbox(chatId: Int64, clientRandomIds: [Int64]) -> AsyncValueObservation<[Qqbridge_V1_OutboxEntry]> {
    ValueObservation.tracking { db in
      guard !clientRandomIds.isEmpty else { return [Qqbridge_V1_OutboxEntry]() }
      let placeholders = Array(repeating: "?", count: clientRandomIds.count).joined(separator: ",")
      return try Data.fetchAll(db,
        sql: "select data from outbox where chatId = ? and clientRandomId in (\(placeholders))",
        arguments: StatementArguments([chatId] + clientRandomIds))
        .map { try Qqbridge_V1_OutboxEntry(serializedBytes: $0) }
    }
    .removeDuplicates()
    .values(in: db)
  }

  /// 会话列表（置顶在前，然后按最后一条消息时间倒序），带上对方资料。
  public func observeDialogs(limit: Int = 500) -> AsyncValueObservation<[DialogItem]> {
    ValueObservation.tracking { db in try Self.dialogItems(db, limit: limit) }
      .removeDuplicates()
      .values(in: db)
  }

  /// 等待指定会话同步落库，不受会话列表的排序和数量上限影响。
  public func observeDialog(chatId: Int64) -> AsyncValueObservation<Qqbridge_V1_Dialog?> {
    ValueObservation.tracking { db in
      try Data.fetchOne(db, sql: "select data from dialog where chatId = ?", arguments: [chatId])
        .map { try Qqbridge_V1_Dialog(serializedBytes: $0) }
    }
    .removeDuplicates()
    .values(in: db)
  }

  /// 会话列表的一次性快照（不观察变化）。
  public func dialogItems(limit: Int = 500) throws -> [DialogItem] {
    try db.read { db in try Self.dialogItems(db, limit: limit) }
  }

  static func dialogItems(_ db: Database, limit: Int) throws -> [DialogItem] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        select d.data as dialog, p.data as peer from dialog d
        left join peer p on p.qqAccountId = d.qqAccountId and p.peerId = d.peerId
                        and p.kind = case d.scene when ? then ? else ? end
        order by d.pinned desc, d.topTime desc limit ?
        """,
      arguments: [Qqbridge_V1_Scene.group.rawValue, Qqbridge_V1_PeerKind.group.rawValue, Qqbridge_V1_PeerKind.user.rawValue, limit]
    )
    let items = try rows.map { row in
      DialogItem(
        dialog: try Qqbridge_V1_Dialog(serializedBytes: row["dialog"] as Data),
        peer: try (row["peer"] as Data?).map { try Qqbridge_V1_Peer(serializedBytes: $0) }
      )
    }
    // 置顶的按置顶时间倒序（最近置顶的在最上面），其余按最后一条消息时间倒序。
    return items.sorted { a, b in
      if a.dialog.pinned != b.dialog.pinned { return a.dialog.pinned }
      if a.dialog.pinned, a.dialog.pinnedAt != b.dialog.pinnedAt { return a.dialog.pinnedAt > b.dialog.pinnedAt }
      return a.dialog.topTime > b.dialog.topTime
    }
  }

  /// 一个会话最近 limit 条消息（以及这段时间里的服务事件、还没发出去的消息），按时间升序。
  public func observeChat(chatId: Int64, limit: Int) -> AsyncValueObservation<[ChatItem]> {
    ValueObservation.tracking { db in
      // 只显示最新那段连续加载的消息（以及之后实时收到的）：单独拉回来的旧消息（例如回复引用的原消息）
      // 和最新这段不连续，混进来会让日期乱跳、中间缺一大段。
      let floor = try LocalStore.chatState(chatId, db).newestLoadedLowerBound ?? 0
      let messages = try Data.fetchAll(
        db,
        sql: "select data from message where chatId = ? and seq >= ? order by seq desc limit ?",
        arguments: [chatId, floor, limit]
      ).reversed().map { try Qqbridge_V1_Message(serializedBytes: $0) }
      let from = messages.first?.time ?? 0
      let events = try Data.fetchAll(
        db,
        sql: "select data from chatEvent where chatId = ? and time >= ? order by time, id",
        arguments: [chatId, from]
      ).map { try Qqbridge_V1_ChatEvent(serializedBytes: $0) }
      // 已发出的也要取：「已发送」和 QQ 那边的消息分两路到，消息没到之前还得占着位置（见 pairOutbox）。
      let recent = Int64(Date().timeIntervalSince1970) - 3600
      let outbox = try Data.fetchAll(
        db,
        sql: "select data from outbox where chatId = ? and (state <> ? or createdAt >= ?) order by createdAt",
        arguments: [chatId, Qqbridge_V1_OutboxState.sent.rawValue, recent]
      ).map { try Qqbridge_V1_OutboxEntry(serializedBytes: $0) }
      let sentSeqs = outbox.filter { $0.state == .sent && $0.seq > 0 }.map(\.seq)
      let present = sentSeqs.isEmpty ? Set<Int64>() : Set(try Int64.fetchAll(
        db,
        sql: "select seq from message where chatId = ? and seq in (\(Array(repeating: "?", count: sentSeqs.count).joined(separator: ",")))",
        arguments: StatementArguments([chatId] + sentSeqs)
      ))
      let selfUin = try Int64.fetchOne(
        db,
        sql: "select k.value from dialog d join kv k on k.key = 'self:' || d.qqAccountId where d.chatId = ?",
        arguments: [chatId]
      ) ?? 0

      var items: [ChatItem] = messages.map { .message($0) } + events.map { .event($0) }
      items.sort { a, b in a.time == b.time ? a.id < b.id : a.time < b.time }
      let pending = Self.pairOutbox(outbox, messages: messages, presentSeqs: present, selfUin: selfUin)
      return items + pending.map { .outgoing($0) }
    }
    .removeDuplicates()
    .values(in: db)
  }

  /// 发件箱里哪些还要显示成「发送中 / 失败」。2026-10-23 用户反馈同一条消息同时出现实心（已到）和发送中两份，
  /// 或者发出后消失一阵：发件箱的「已发送」（带 seq）和 QQ 那边的消息经两路同步，先后不定。
  /// - 已发送且知道 seq：本地有了这条消息才收起，之前继续占位；
  /// - 其余（发送中、失败、已发送但没拿到 seq）：自己发的、时间不早于创建时间、内容一样的消息到了就收起，
  ///   一条消息只对应一条发件箱条目（连发两条一样的也一一对上）；已发送但没拿到 seq 又对不上的照旧不显示。
  static func pairOutbox(_ outbox: [Qqbridge_V1_OutboxEntry], messages: [Qqbridge_V1_Message],
                         presentSeqs: Set<Int64>, selfUin: Int64) -> [Qqbridge_V1_OutboxEntry] {
    var claimed = Set(outbox.filter { $0.state == .sent && $0.seq > 0 }.map(\.seq))
    let mine = messages.filter { $0.senderID == selfUin && selfUin != 0 && $0.kind != .service }
    var shown: [Qqbridge_V1_OutboxEntry] = []
    for entry in outbox.sorted(by: { $0.createdAt < $1.createdAt }) {
      if entry.state == .sent, entry.seq > 0 {
        if !presentSeqs.contains(entry.seq) { shown.append(entry) }
        continue
      }
      let signature = OutboxSignature.of(entry.segments)
      // 服务端记的创建时间和 QQ 的消息时间来自不同的钟，留 10 秒余量。
      if let match = mine.first(where: { m in
        !claimed.contains(m.seq) && m.time >= entry.createdAt - 10 && OutboxSignature.of(m.segments) == signature
      }) {
        claimed.insert(match.seq)
        continue
      }
      if entry.state != .sent { shown.append(entry) }
    }
    return shown
  }

  /// 一条消息：本地库里这条有变化（例如缩略图、视频封面下好了）就推一次新的。本地还没有时推 nil。
  public func observeMessage(chatId: Int64, seq: Int64) -> AsyncValueObservation<Qqbridge_V1_Message?> {
    ValueObservation.tracking { db in
      try Data.fetchOne(db, sql: "select data from message where chatId = ? and seq = ?", arguments: [chatId, seq])
        .map { try Qqbridge_V1_Message(serializedBytes: $0) }
    }
    .removeDuplicates()
    .values(in: db)
  }

  /// 某个会话的对方资料（聊天页标题用）。
  public func observePeer(for dialog: Qqbridge_V1_Dialog) -> AsyncValueObservation<Qqbridge_V1_Peer?> {
    let kind: Qqbridge_V1_PeerKind = dialog.scene == .group ? .group : .user
    return ValueObservation.tracking { db in
      try Data.fetchOne(
        db,
        sql: "select data from peer where qqAccountId = ? and kind = ? and peerId = ?",
        arguments: [dialog.qqAccountID, kind.rawValue, dialog.peerID]
      ).map { try Qqbridge_V1_Peer(serializedBytes: $0) }
    }
    .removeDuplicates()
    .values(in: db)
  }

  /// 群里发言人的显示名（群名片 / 昵称 / 号码），没有资料时返回 nil。
  public func userName(qqAccountId: Int64, userId: Int64) throws -> String? {
    try peer(qqAccountId: qqAccountId, kind: .user, peerId: userId).map { p in
      !p.remark.isEmpty ? p.remark : (!p.name.isEmpty ? p.name : String(userId))
    }
  }
}

/// 比较发件箱条目和收到的消息是不是同一条：只看内容的骨架（文字去掉空白，@ 看 QQ 号，表情看 id，媒体只看种类）。
/// 回复引用不算在内：QQ 回来的消息把引用放成单独一段，发件箱是 reply_to_seq。
enum OutboxSignature {
  static func of(_ segments: [Qqbridge_V1_OutgoingSegment]) -> [String] {
    join(segments.map { seg -> String? in
      switch seg.kind {
      case .text(let t): "t:" + t
      case .mentionUserID(let u): "@\(u)"
      case .mentionAll: "@all"
      case .faceID(let f): "f:\(f)"
      case .image: "image"
      case .record: "record"
      case .video: "video"
      case .file(let f): "file:" + f.name
      case .forward: "forward"
      case .none: nil
      }
    })
  }

  static func of(_ segments: [Qqbridge_V1_Segment]) -> [String] {
    join(segments.map { seg -> String? in
      switch seg.kind {
      case .text(let t): "t:" + t.text
      case .mention(let m): "@\(m.userID)"
      case .mentionAll: "@all"
      case .face(let f): "f:" + f.faceID
      case .reply: nil
      case .image, .marketFace: "image"
      case .record: "record"
      case .video: "video"
      case .file(let f): "file:" + f.name
      case .forward: "forward"
      default: "other"
      }
    })
  }

  /// 相邻的文字合成一段再去掉空白（@ 后面跟的空格、QQ 拆开的文字段都不影响）。
  private static func join(_ tokens: [String?]) -> [String] {
    var out: [String] = []
    var text = ""
    func flush() {
      let compact = text.filter { !$0.isWhitespace }
      if !compact.isEmpty { out.append("t:" + compact) }
      text = ""
    }
    for token in tokens.compactMap({ $0 }) {
      if token.hasPrefix("t:") { text += token.dropFirst(2) } else { flush(); out.append(token) }
    }
    flush()
    return out
  }
}
