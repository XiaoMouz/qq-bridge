import Foundation

@main
struct NotificationReadCheck {
  static func main() {
    // 本地仍是已读到 100 的旧快照，新消息 101 的 APNs 比 Subscribe 更早到。
    let oldSnapshot: [Int64: Int64] = [153: 100, 200: 50]
    precondition(!NotificationReadPolicy.isRead(chatId: 153, seq: 101, readThrough: oldSnapshot))
    // 同一聊天既有旧通知又有新的未读消息，只移除已读的那一部分。
    precondition(NotificationReadPolicy.isRead(chatId: 153, seq: 99, readThrough: oldSnapshot))
    precondition(NotificationReadPolicy.isRead(chatId: 153, seq: 100, readThrough: oldSnapshot))
    // 其他设备读到 101 后，本地同步推进游标，才能清除 101。
    precondition(NotificationReadPolicy.isRead(chatId: 153, seq: 101, readThrough: [153: 101]))
    // 不串会话；未知会话、来电、旧格式及调试通知不能按消息已读状态删除。
    precondition(!NotificationReadPolicy.isRead(chatId: 200, seq: 100, readThrough: oldSnapshot))
    precondition(!NotificationReadPolicy.isRead(chatId: 999, seq: 1, readThrough: oldSnapshot))
    precondition(!NotificationReadPolicy.isRead(chatId: 153, seq: nil, readThrough: oldSnapshot))
    precondition(!NotificationReadPolicy.isRead(chatId: 153, seq: 0, readThrough: oldSnapshot))
    precondition(!NotificationReadPolicy.isRead(chatId: nil, seq: 1, readThrough: oldSnapshot))
    print("通知清理检查通过：推送早于同步、部分已读、跨设备游标推进及无消息序号通知")
  }
}
