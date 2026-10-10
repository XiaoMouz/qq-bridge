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
  /// 会话列表（置顶在前，然后按最后一条消息时间倒序），带上对方资料。
  public func observeDialogs(limit: Int = 500) -> AsyncValueObservation<[DialogItem]> {
    ValueObservation.tracking { db in
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
      return try rows.map { row in
        DialogItem(
          dialog: try Qqbridge_V1_Dialog(serializedBytes: row["dialog"] as Data),
          peer: try (row["peer"] as Data?).map { try Qqbridge_V1_Peer(serializedBytes: $0) }
        )
      }
    }
    .removeDuplicates()
    .values(in: db)
  }

  /// 一个会话最近 limit 条消息（以及这段时间里的服务事件、还没发出去的消息），按时间升序。
  public func observeChat(chatId: Int64, limit: Int) -> AsyncValueObservation<[ChatItem]> {
    ValueObservation.tracking { db in
      let messages = try Data.fetchAll(
        db,
        sql: "select data from message where chatId = ? order by seq desc limit ?",
        arguments: [chatId, limit]
      ).reversed().map { try Qqbridge_V1_Message(serializedBytes: $0) }
      let from = messages.first?.time ?? 0
      let events = try Data.fetchAll(
        db,
        sql: "select data from chatEvent where chatId = ? and time >= ? order by time, id",
        arguments: [chatId, from]
      ).map { try Qqbridge_V1_ChatEvent(serializedBytes: $0) }
      // 已发出的不再单独显示：QQ 那边的消息会经同步进来。
      let outbox = try Data.fetchAll(
        db,
        sql: "select data from outbox where chatId = ? and state <> ? order by createdAt",
        arguments: [chatId, Qqbridge_V1_OutboxState.sent.rawValue]
      ).map { try Qqbridge_V1_OutboxEntry(serializedBytes: $0) }

      var items: [ChatItem] = messages.map { .message($0) } + events.map { .event($0) }
      items.sort { a, b in a.time == b.time ? a.id < b.id : a.time < b.time }
      return items + outbox.map { .outgoing($0) }
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
