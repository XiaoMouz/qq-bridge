// 本地库（docs/design.md 6.2 / 6.3）：服务端是唯一真相源，这里只是有上限的缓存。
// - 每行同时存 protobuf 原文（data）和需要查询、排序的列；界面按列查，取到行再解出完整消息。
// - 每个会话记自己的 chat_pts 和已加载的连续 seq 区间（loaded_ranges），翻页、补洞据此判断。
// - 放在 App Group 容器里，App 与通知扩展、分享扩展共用。
import Foundation
import GRDB
import QQBridgeProto
import SwiftProtobuf

public final class LocalStore: Sendable {
  public let db: any DatabaseWriter

  /// 磁盘上的库（App 用 App Group 目录下的文件）。
  public static func open(at url: URL) throws -> LocalStore {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var config = Configuration()
    config.foreignKeysEnabled = true
    return try LocalStore(db: DatabasePool(path: url.path, configuration: config))
  }

  /// 内存库（测试、预览用）。
  public static func inMemory() throws -> LocalStore {
    try LocalStore(db: DatabaseQueue())
  }

  init(db: any DatabaseWriter) throws {
    self.db = db
    try Self.migrator.migrate(db)
  }

  static var migrator: DatabaseMigrator {
    var m = DatabaseMigrator()
    m.registerMigration("v1") { db in
      try db.create(table: "kv") { t in
        t.primaryKey("key", .text)
        t.column("value", .integer).notNull()
      }
      try db.create(table: "dialog") { t in
        t.primaryKey("chatId", .integer)
        t.column("qqAccountId", .integer).notNull()
        t.column("scene", .integer).notNull()
        t.column("peerId", .integer).notNull()
        t.column("topTime", .integer).notNull()
        t.column("pinned", .boolean).notNull()
        t.column("unreadCount", .integer).notNull()
        t.column("data", .blob).notNull()
      }
      try db.create(index: "dialog_order", on: "dialog", columns: ["pinned", "topTime"])
      try db.create(table: "peer") { t in
        t.column("qqAccountId", .integer).notNull()
        t.column("kind", .integer).notNull()
        t.column("peerId", .integer).notNull()
        t.column("data", .blob).notNull()
        t.primaryKey(["qqAccountId", "kind", "peerId"])
      }
      try db.create(table: "chatState") { t in
        t.primaryKey("chatId", .integer)
        /// 0 = 本地还没有这个会话的消息。
        t.column("chatPts", .integer).notNull()
        /// JSON：[[lo, hi], ...]，已加载的连续 seq 区间（闭区间），按 lo 升序、互不重叠。
        t.column("loadedRanges", .text).notNull()
        t.column("lastOpenedAt", .integer)
      }
      try db.create(table: "message") { t in
        t.column("chatId", .integer).notNull()
        t.column("seq", .integer).notNull()
        t.column("version", .integer).notNull()
        t.column("time", .integer).notNull()
        t.column("senderId", .integer).notNull()
        t.column("data", .blob).notNull()
        t.primaryKey(["chatId", "seq"])
      }
      try db.create(table: "chatEvent") { t in
        t.primaryKey("id", .integer)
        t.column("chatId", .integer).notNull()
        t.column("version", .integer).notNull()
        t.column("time", .integer).notNull()
        t.column("data", .blob).notNull()
      }
      try db.create(index: "chatEvent_time", on: "chatEvent", columns: ["chatId", "time"])
      try db.create(table: "outbox") { t in
        t.primaryKey("clientRandomId", .integer)
        t.column("chatId", .integer).notNull()
        t.column("state", .integer).notNull()
        t.column("createdAt", .integer).notNull()
        t.column("data", .blob).notNull()
      }
      try db.create(table: "mediaCache") { t in
        t.primaryKey("sha256", .text)
        t.column("size", .integer).notNull()
        t.column("createdAt", .integer).notNull()
        t.column("lastAccessAt", .integer).notNull()
        /// 来自哪个会话（按会话清理缓存用；同一内容可能出现在多个会话，记第一次缓存时的）。
        t.column("chatId", .integer)
      }
      try db.create(index: "mediaCache_lru", on: "mediaCache", columns: ["lastAccessAt"])
    }
    return m
  }
}

// MARK: - 全局状态

extension LocalStore {
  public func pts() throws -> Int64 {
    try db.read { db in try Int64.fetchOne(db, sql: "select value from kv where key = 'pts'") ?? 0 }
  }

  /// 记下本账号下各 QQ 号（qq_account_id → QQ 号），判断消息是不是自己发的。
  public func setQqAccounts(_ accounts: [Qqbridge_V1_QqAccountInfo]) throws {
    try db.write { db in
      for a in accounts {
        try db.execute(
          sql: "insert into kv (key, value) values (?, ?) on conflict(key) do update set value = excluded.value",
          arguments: ["self:\(a.id)", a.uin]
        )
      }
    }
  }

  /// 某个 QQ 号（qq_account_id）自己的号码；不知道时为 0。
  public func selfUin(qqAccountId: Int64) throws -> Int64 {
    try db.read { db in try Int64.fetchOne(db, sql: "select value from kv where key = ?", arguments: ["self:\(qqAccountId)"]) ?? 0 }
  }

  /// 清空全部缓存（服务端要求重新同步、换账号时）。
  public func reset() throws {
    try db.write { db in
      for table in ["dialog", "peer", "chatState", "message", "chatEvent", "outbox"] {
        try db.execute(sql: "delete from \(table)")
      }
      try db.execute(sql: "delete from kv where key = 'pts'")
    }
  }
}

// MARK: - 会话列表、联系人（全局 pts）

extension LocalStore {
  /// 应用一页差量：会话、资料、墓碑、发件箱，并把游标推进到 difference.pts。
  public func apply(difference d: Qqbridge_V1_Difference) throws {
    try db.write { db in
      for dialog in d.dialogs { try Self.upsert(dialog: dialog, db) }
      for peer in d.peers { try Self.upsert(peer: peer, db) }
      for t in d.tombstones { try Self.apply(tombstone: t, db) }
      for o in d.outbox { try Self.upsert(outbox: o, db) }
      try Self.setPts(d.pts, db)
    }
  }

  public func apply(dialog: Qqbridge_V1_Dialog, pts: Int64) throws {
    try db.write { db in
      try Self.upsert(dialog: dialog, db)
      try Self.setPts(pts, db)
    }
  }

  public func apply(peer: Qqbridge_V1_Peer, pts: Int64) throws {
    try db.write { db in
      try Self.upsert(peer: peer, db)
      try Self.setPts(pts, db)
    }
  }

  public func apply(tombstone: Qqbridge_V1_Tombstone, pts: Int64) throws {
    try db.write { db in
      try Self.apply(tombstone: tombstone, db)
      try Self.setPts(pts, db)
    }
  }

  public func apply(outbox: Qqbridge_V1_OutboxEntry, pts: Int64) throws {
    try db.write { db in
      try Self.upsert(outbox: outbox, db)
      try Self.setPts(pts, db)
    }
  }

  /// 会话列表：置顶在前，然后按最后一条消息时间倒序。
  public func dialogs(limit: Int = 500) throws -> [Qqbridge_V1_Dialog] {
    try db.read { db in
      try Data.fetchAll(db, sql: "select data from dialog order by pinned desc, topTime desc limit ?", arguments: [limit])
        .map { try Qqbridge_V1_Dialog(serializedBytes: $0) }
    }
  }

  public func dialog(chatId: Int64) throws -> Qqbridge_V1_Dialog? {
    try db.read { db in
      try Data.fetchOne(db, sql: "select data from dialog where chatId = ?", arguments: [chatId]).map { try Qqbridge_V1_Dialog(serializedBytes: $0) }
    }
  }

  public func peer(qqAccountId: Int64, kind: Qqbridge_V1_PeerKind, peerId: Int64) throws -> Qqbridge_V1_Peer? {
    try db.read { db in
      try Data.fetchOne(
        db,
        sql: "select data from peer where qqAccountId = ? and kind = ? and peerId = ?",
        arguments: [qqAccountId, kind.rawValue, peerId]
      ).map { try Qqbridge_V1_Peer(serializedBytes: $0) }
    }
  }

  /// 最新那段连续加载区间里的消息条数（聊天页能显示的上限）和区间下界。
  public func loadedWindow(chatId: Int64) throws -> (count: Int, floor: Int64) {
    try db.read { db in
      let floor = try Self.chatState(chatId, db).newestLoadedLowerBound ?? 0
      let count = try Int.fetchOne(db, sql: "select count(*) from message where chatId = ? and seq >= ?", arguments: [chatId, floor]) ?? 0
      return (count, floor)
    }
  }

  /// 本地有的、seq 不小于 fromSeq 的消息条数（跳到某条消息时，用来算聊天页至少要显示多少条）。
  public func messageCount(chatId: Int64, fromSeq: Int64) throws -> Int {
    try db.read { db in
      try Int.fetchOne(db, sql: "select count(*) from message where chatId = ? and seq >= ?", arguments: [chatId, fromSeq]) ?? 0
    }
  }

  /// 不指定 QQ 号查联系人 / 群（只登录一个 QQ 号时用；资料页先用它显示，再等服务端刷新）。
  public func peer(kind: Qqbridge_V1_PeerKind, peerId: Int64) throws -> Qqbridge_V1_Peer? {
    try db.read { db in
      try Data.fetchOne(
        db,
        sql: "select data from peer where kind = ? and peerId = ? limit 1",
        arguments: [kind.rawValue, peerId]
      ).map { try Qqbridge_V1_Peer(serializedBytes: $0) }
    }
  }

  /// 本地缓存的全部好友 / 群（联系人页先显示它，再等服务端的列表和分组）。
  public func peers(kind: Qqbridge_V1_PeerKind, friendsOnly: Bool = false) throws -> [Qqbridge_V1_Peer] {
    try db.read { db in
      try Data.fetchAll(db, sql: "select data from peer where kind = ?", arguments: [kind.rawValue])
        .map { try Qqbridge_V1_Peer(serializedBytes: $0) }
        .filter { !friendsOnly || $0.isFriend }
    }
  }

  public func outbox(chatId: Int64) throws -> [Qqbridge_V1_OutboxEntry] {
    try db.read { db in
      try Data.fetchAll(db, sql: "select data from outbox where chatId = ? order by createdAt", arguments: [chatId])
        .map { try Qqbridge_V1_OutboxEntry(serializedBytes: $0) }
    }
  }

  static func setPts(_ pts: Int64, _ db: Database) throws {
    // 游标只前进（同一页里乱序到达的更新不会把它拨回去）。
    try db.execute(
      sql: "insert into kv (key, value) values ('pts', ?) on conflict(key) do update set value = max(value, excluded.value)",
      arguments: [pts]
    )
  }

  static func upsert(dialog d: Qqbridge_V1_Dialog, _ db: Database) throws {
    try db.execute(
      sql: """
        insert into dialog (chatId, qqAccountId, scene, peerId, topTime, pinned, unreadCount, data) values (?, ?, ?, ?, ?, ?, ?, ?)
        on conflict(chatId) do update set qqAccountId = excluded.qqAccountId, scene = excluded.scene, peerId = excluded.peerId,
          topTime = excluded.topTime, pinned = excluded.pinned, unreadCount = excluded.unreadCount, data = excluded.data
        """,
      arguments: [d.chatID, d.qqAccountID, d.scene.rawValue, d.peerID, d.topTime, d.pinned, d.unreadCount, try d.serializedData()]
    )
  }

  static func upsert(peer p: Qqbridge_V1_Peer, _ db: Database) throws {
    try db.execute(
      sql: """
        insert into peer (qqAccountId, kind, peerId, data) values (?, ?, ?, ?)
        on conflict(qqAccountId, kind, peerId) do update set data = excluded.data
        """,
      arguments: [p.qqAccountID, p.kind.rawValue, p.peerID, try p.serializedData()]
    )
  }

  static func upsert(outbox o: Qqbridge_V1_OutboxEntry, _ db: Database) throws {
    try db.execute(
      sql: """
        insert into outbox (clientRandomId, chatId, state, createdAt, data) values (?, ?, ?, ?, ?)
        on conflict(clientRandomId) do update set state = excluded.state, data = excluded.data
        """,
      arguments: [o.clientRandomID, o.chatID, o.state.rawValue, o.createdAt, try o.serializedData()]
    )
  }

  static func apply(tombstone t: Qqbridge_V1_Tombstone, _ db: Database) throws {
    switch t.entity {
    case "dialog", "chat":
      guard let chatId = Int64(t.key) else { return }
      for table in ["dialog", "chatState", "message", "chatEvent", "outbox"] {
        try db.execute(sql: "delete from \(table) where chatId = ?", arguments: [chatId])
      }
    case "outbox":
      try db.execute(sql: "delete from outbox where clientRandomId = ?", arguments: [Int64(t.key) ?? 0])
    default:
      break  // 以后的新实体：不认识就忽略
    }
  }
}

// MARK: - 会话里的消息（chat_pts）

/// 已加载的连续 seq 区间（闭区间）。
public struct SeqRange: Codable, Equatable, Sendable {
  public var lo: Int64
  public var hi: Int64
  public init(_ lo: Int64, _ hi: Int64) {
    self.lo = lo
    self.hi = hi
  }
}

public struct ChatState: Equatable, Sendable {
  public var chatPts: Int64
  public var loadedRanges: [SeqRange]
  /// 最新那段已加载区间的下界（往上翻页从这里继续）；没加载过为 nil。
  public var newestLoadedLowerBound: Int64? { loadedRanges.last?.lo }
}

extension LocalStore {
  public func chatState(chatId: Int64) throws -> ChatState {
    try db.read { db in try Self.chatState(chatId, db) }
  }

  /// 应用一个会话的变化：消息与服务事件按版本号覆盖，chat_pts 前进到 newChatPts。
  /// - reset：服务端说变化太多（too_long），丢掉本地窗口，以这一页为准重新开始。
  /// - contiguous：这一页是从某个 seq 往前连续的一段（首屏、翻页），可以并入已加载区间。
  public func applyChat(
    chatId: Int64,
    messages: [Qqbridge_V1_Message],
    events: [Qqbridge_V1_ChatEvent],
    newChatPts: Int64?,
    reset: Bool = false,
    contiguous: SeqRange? = nil
  ) throws {
    try db.write { db in
      var state = try Self.chatState(chatId, db)
      if reset {
        try db.execute(sql: "delete from message where chatId = ?", arguments: [chatId])
        try db.execute(sql: "delete from chatEvent where chatId = ?", arguments: [chatId])
        state.loadedRanges = []
      }
      for m in messages {
        try db.execute(
          sql: """
            insert into message (chatId, seq, version, time, senderId, data) values (?, ?, ?, ?, ?, ?)
            on conflict(chatId, seq) do update set version = excluded.version, time = excluded.time,
              senderId = excluded.senderId, data = excluded.data
            where excluded.version >= message.version
            """,
          arguments: [chatId, m.seq, m.version, m.time, m.senderID, try m.serializedData()]
        )
      }
      for e in events {
        try db.execute(
          sql: """
            insert into chatEvent (id, chatId, version, time, data) values (?, ?, ?, ?, ?)
            on conflict(id) do update set version = excluded.version, time = excluded.time, data = excluded.data
            where excluded.version >= chatEvent.version
            """,
          arguments: [e.id, chatId, e.version, e.time, try e.serializedData()]
        )
      }
      if let range = contiguous { state.loadedRanges = Self.merge(state.loadedRanges, range) }
      if let pts = newChatPts { state.chatPts = max(reset ? 0 : state.chatPts, pts) }
      try Self.save(chatId, state, db)
    }
  }

  /// 本地已有的消息，按 seq 升序；beforeSeq 为 nil 表示从最新开始。
  public func messages(chatId: Int64, beforeSeq: Int64? = nil, limit: Int = 50) throws -> [Qqbridge_V1_Message] {
    try db.read { db in
      let rows = try Data.fetchAll(
        db,
        sql: "select data from message where chatId = ? and seq < ? order by seq desc limit ?",
        arguments: [chatId, beforeSeq ?? Int64.max, limit]
      )
      return try rows.reversed().map { try Qqbridge_V1_Message(serializedBytes: $0) }
    }
  }

  /// 本地的某一条消息。
  public func message(chatId: Int64, seq: Int64) throws -> Qqbridge_V1_Message? {
    try db.read { db in
      try Data.fetchOne(db, sql: "select data from message where chatId = ? and seq = ?", arguments: [chatId, seq])
        .map { try Qqbridge_V1_Message(serializedBytes: $0) }
    }
  }

  public func events(chatId: Int64, fromTime: Int64, toTime: Int64) throws -> [Qqbridge_V1_ChatEvent] {
    try db.read { db in
      try Data.fetchAll(
        db,
        sql: "select data from chatEvent where chatId = ? and time between ? and ? order by time, id",
        arguments: [chatId, fromTime, toTime]
      ).map { try Qqbridge_V1_ChatEvent(serializedBytes: $0) }
    }
  }

  public func markOpened(chatId: Int64, at: Date = Date()) throws {
    try db.write { db in
      try Self.save(chatId, try Self.chatState(chatId, db), db)  // 确保有这一行
      try db.execute(sql: "update chatState set lastOpenedAt = ? where chatId = ?", arguments: [Int64(at.timeIntervalSince1970), chatId])
    }
  }

  /// 本地消息裁剪（docs/design.md 6.3）：每个会话只留最近 keepPerChat 条，并且不早于 keepDays 天；
  /// 被裁掉的部分从已加载区间里去掉，翻页时再向服务端要。返回删除的消息数。
  @discardableResult
  public func trimMessages(keepPerChat: Int = 2000, keepDays: Int = 30, now: Date = Date()) throws -> Int {
    let cutoff = Int64(now.timeIntervalSince1970) - Int64(keepDays) * 86400
    return try db.write { db in
      var deleted = 0
      let chats = try Int64.fetchAll(db, sql: "select distinct chatId from message")
      for chatId in chats {
        // 保留：最新 keepPerChat 条里不早于 cutoff 的；至少留最新一屏（50 条），打开会话不会是空的。
        let floor = try Int64.fetchOne(
          db,
          sql: """
            select min(seq) from (select seq, time from message where chatId = ? order by seq desc limit ?)
             where time >= ? or seq >= (select min(seq) from (select seq from message where chatId = ? order by seq desc limit 50))
            """,
          arguments: [chatId, keepPerChat, cutoff, chatId]
        )
        guard let floor else { continue }
        try db.execute(sql: "delete from message where chatId = ? and seq < ?", arguments: [chatId, floor])
        deleted += db.changesCount
        var state = try Self.chatState(chatId, db)
        state.loadedRanges = state.loadedRanges.compactMap { r in
          r.hi < floor ? nil : SeqRange(max(r.lo, floor), r.hi)
        }
        try Self.save(chatId, state, db)
      }
      return deleted
    }
  }

  static func chatState(_ chatId: Int64, _ db: Database) throws -> ChatState {
    guard let row = try Row.fetchOne(db, sql: "select chatPts, loadedRanges from chatState where chatId = ?", arguments: [chatId]) else {
      return ChatState(chatPts: 0, loadedRanges: [])
    }
    let ranges = (try? JSONDecoder().decode([SeqRange].self, from: Data((row["loadedRanges"] as String).utf8))) ?? []
    return ChatState(chatPts: row["chatPts"], loadedRanges: ranges)
  }

  static func save(_ chatId: Int64, _ state: ChatState, _ db: Database) throws {
    let json = String(decoding: try JSONEncoder().encode(state.loadedRanges), as: UTF8.self)
    try db.execute(
      sql: """
        insert into chatState (chatId, chatPts, loadedRanges) values (?, ?, ?)
        on conflict(chatId) do update set chatPts = excluded.chatPts, loadedRanges = excluded.loadedRanges
        """,
      arguments: [chatId, state.chatPts, json]
    )
  }

  /// 并入一个区间，相邻或重叠的合并。
  static func merge(_ ranges: [SeqRange], _ add: SeqRange) -> [SeqRange] {
    var out: [SeqRange] = []
    for r in (ranges + [add]).sorted(by: { $0.lo < $1.lo }) where r.lo <= r.hi {
      if var last = out.last, r.lo <= last.hi + 1 {
        last.hi = max(last.hi, r.hi)
        out[out.count - 1] = last
      } else {
        out.append(r)
      }
    }
    return out
  }
}
