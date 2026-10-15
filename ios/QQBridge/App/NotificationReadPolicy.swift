import Foundation

/// 推送可能先于 Subscribe 到达，旧快照的 unreadCount == 0 不能证明这条推送已读。
/// 只清除有明确消息序号、且已被当前已读游标覆盖的通知；来电等无序号通知不属于此清理策略。
enum NotificationReadPolicy {
  static func isRead(chatId: Int64?, seq: Int64?, readThrough: [Int64: Int64]) -> Bool {
    guard let chatId, let seq, seq > 0, let lastRead = readThrough[chatId] else { return false }
    return seq <= lastRead
  }
}
