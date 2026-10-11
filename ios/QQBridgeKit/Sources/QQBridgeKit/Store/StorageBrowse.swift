// 本机存储的浏览：缓存的媒体按类型（图片、表情、视频、文件、语音）统计，再按会话、按具体文件细看；
// 消息本身按会话统计。和别的会话共用的内容（同一份 sha256 出现在多个会话）标出来。
import Foundation
import GRDB
import QQBridgeProto

public enum LocalStorageKind: String, Sendable, CaseIterable {
  case image, sticker, video, audio, file, other
}

public struct LocalStorageChat: Sendable, Identifiable {
  public let chatId: Int64
  public let bytes: Int64
  public let count: Int
  public var id: Int64 { chatId }
}

public struct LocalStorageItem: Sendable, Identifiable {
  public let sha256: String
  public let size: Int64
  public let kind: LocalStorageKind
  /// 第一次出现的会话、消息（没有记录的为 0）。
  public let chatId: Int64
  public let seq: Int64
  /// 引用它的会话数（> 1 = 共用）。
  public let refChats: Int
  public var id: String { sha256 }
}

extension LocalStore {
  /// 记下一条消息里的媒体（各个 sha256 → 类型）。
  static func indexMedia(_ m: Qqbridge_V1_Message, chatId: Int64, _ db: Database) throws {
    for seg in m.segments {
      let media: Qqbridge_V1_MediaInfo
      let kind: LocalStorageKind
      switch seg.kind {
      case .image(let i):
        media = i.media
        kind = i.sticker ? .sticker : .image
      case .marketFace(let f) where f.hasMedia:
        media = f.media
        kind = .sticker
      case .video(let v):
        media = v.media
        kind = .video
      case .record(let r):
        media = r.media
        kind = .audio
      case .file(let f):
        media = f.media
        kind = .file
      default:
        continue
      }
      for sha in Set([media.sha256, media.thumbSha256, media.previewSha256, media.playableSha256]) where !sha.isEmpty {
        try db.execute(
          sql: "insert or ignore into mediaIndex (sha256, chatId, seq, kind) values (?, ?, ?, ?)",
          arguments: [sha, chatId, m.seq, kind.rawValue]
        )
      }
    }
  }

  /// 给建索引之前就有的消息补上媒体索引：按 rowid 分批（每批 500 条）在后台做，进度记在 kv 里，中断了下次接着补。
  public func backfillMediaIndex() async {
    let key = "mediaIndexBackfill"
    while !Task.isCancelled {
      let done: Bool? = try? await db.write { db in
        let from = try Int64.fetchOne(db, sql: "select value from kv where key = ?", arguments: [key]) ?? 0
        guard from >= 0 else { return true }
        let rows = try Row.fetchAll(db, sql: "select rowid, chatId, data from message where rowid > ? order by rowid limit 500", arguments: [from])
        for row in rows {
          if let m = try? Qqbridge_V1_Message(serializedBytes: row["data"] as Data) { try Self.indexMedia(m, chatId: row["chatId"], db) }
        }
        let next: Int64 = rows.last.map { $0["rowid"] } ?? -1
        try db.execute(sql: "insert into kv (key, value) values (?, ?) on conflict(key) do update set value = excluded.value", arguments: [key, next])
        return rows.isEmpty
      }
      if done ?? true { return }
      await Task.yield()
    }
  }

  /// 每个缓存文件归到一类（同一份出现在不同类型里时取第一个）；没记录的（头像等）算 other。
  private static let kindOf = """
    (select sha256, min(kind) as kind from mediaIndex group by sha256)
    """

  /// 本机缓存按类型：字节数、文件数。
  public func cacheUsageByKind() throws -> [LocalStorageKind: (bytes: Int64, count: Int)] {
    try db.read { db in
      var out: [LocalStorageKind: (bytes: Int64, count: Int)] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          select coalesce(k.kind, 'other') as kind, sum(c.size) as bytes, count(*) as n
            from mediaCache c left join \(Self.kindOf) k on k.sha256 = c.sha256 group by 1
          """
      ) {
        out[LocalStorageKind(rawValue: row["kind"]) ?? .other] = (row["bytes"], row["n"])
      }
      return out
    }
  }

  /// 本机消息：数据库文件大小、各会话消息数据的大小。
  public func messageUsage() throws -> (total: Int64, byChat: [LocalStorageChat]) {
    try db.read { db in
      let pages = try Int64.fetchOne(db, sql: "pragma page_count") ?? 0
      let pageSize = try Int64.fetchOne(db, sql: "pragma page_size") ?? 4096
      let chats = try Row.fetchAll(
        db,
        sql: "select chatId, sum(length(data)) as bytes, count(*) as n from message group by chatId order by bytes desc limit 200"
      ).map { LocalStorageChat(chatId: $0["chatId"], bytes: $0["bytes"], count: $0["n"]) }
      return (pages * pageSize, chats)
    }
  }

  /// 某类缓存在各会话的占用（一份内容在几个会话里出现就在几个会话里都算）。
  public func cacheChats(kinds: [LocalStorageKind]) throws -> [LocalStorageChat] {
    try db.read { db in
      let wantsOther = kinds.contains(.other)
      let named = kinds.filter { $0 != .other }.map(\.rawValue)
      var out: [Int64: (Int64, Int)] = [:]
      if !named.isEmpty {
        let marks = named.map { _ in "?" }.joined(separator: ",")
        for row in try Row.fetchAll(
          db,
          sql: """
            select i.chatId, sum(c.size) as bytes, count(*) as n from mediaCache c
              join (select distinct sha256, chatId from mediaIndex where kind in (\(marks))) i on i.sha256 = c.sha256
             group by i.chatId
            """,
          arguments: StatementArguments(named)
        ) {
          out[row["chatId"]] = (row["bytes"], row["n"])
        }
      }
      if wantsOther {
        for row in try Row.fetchAll(
          db,
          sql: """
            select coalesce(chatId, 0) as chatId, sum(size) as bytes, count(*) as n from mediaCache
             where sha256 not in (select sha256 from mediaIndex) group by 1
            """
        ) {
          let prev = out[row["chatId"]] ?? (0, 0)
          out[row["chatId"]] = (prev.0 + row["bytes"], prev.1 + row["n"])
        }
      }
      return out.map { LocalStorageChat(chatId: $0.key, bytes: $0.value.0, count: $0.value.1) }.sorted { $0.bytes > $1.bytes }
    }
  }

  /// 缓存里的具体文件（chatId = nil 时全部），从大到小。
  public func cacheItems(chatId: Int64?, kinds: [LocalStorageKind], limit: Int = 300) throws -> [LocalStorageItem] {
    try db.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          select c.sha256, c.size, coalesce(k.kind, 'other') as kind, coalesce(c.chatId, 0) as cacheChat,
                 (select min(seq) from mediaIndex i where i.sha256 = c.sha256 \(chatId == nil ? "" : "and i.chatId = \(chatId!)")) as seq,
                 (select min(chatId) from mediaIndex i where i.sha256 = c.sha256) as firstChat,
                 (select count(distinct chatId) from mediaIndex i where i.sha256 = c.sha256) as refs
            from mediaCache c left join \(Self.kindOf) k on k.sha256 = c.sha256
           order by c.size desc
          """
      )
      return rows.compactMap { row -> LocalStorageItem? in
        let kind = LocalStorageKind(rawValue: row["kind"]) ?? .other
        guard kinds.contains(kind) else { return nil }
        let seq: Int64? = row["seq"]
        if let chatId {
          // 指定会话：在这个会话里出现过（或没有记录、但是在这个会话里缓存的）。
          if seq == nil && (row["cacheChat"] as Int64) != chatId { return nil }
        }
        let first: Int64? = row["firstChat"]
        return LocalStorageItem(
          sha256: row["sha256"], size: row["size"], kind: kind,
          chatId: chatId ?? first ?? row["cacheChat"], seq: seq ?? 0, refChats: max(1, row["refs"] as Int)
        )
      }
      .prefix(limit)
      .map { $0 }
    }
  }

  /// 引用了这份内容的会话。
  public func chatsReferencing(_ sha256: String) throws -> [(chatId: Int64, seq: Int64)] {
    try db.read { db in
      try Row.fetchAll(db, sql: "select chatId, min(seq) as seq from mediaIndex where sha256 = ? group by chatId", arguments: [sha256])
        .map { ($0["chatId"], $0["seq"]) }
    }
  }
}
