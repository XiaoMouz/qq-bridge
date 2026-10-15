import Testing
@testable import QQBridgeKit

struct HistoryTargetWindowTests {
  @Test func isolatedMessageDoesNotPretendInitialHistoryIsLoaded() throws {
    let store = try LocalStore.inMemory()
    try store.applyChat(chatId: 1, messages: [message(1, 25)], events: [], newChatPts: nil)
    let snapshot = try store.historyTargetWindow(chatId: 1, seq: 25)
    #expect(snapshot.floor == nil && snapshot.containsTarget)
    #expect(snapshot.count == 1 && snapshot.countFromTarget == 1)
  }

  @Test func targetSnapshotSeparatesContinuousHistoryFromIsolatedRowsAndOtherChats() throws {
    let store = try LocalStore.inMemory()
    try store.applyChat(chatId: 1, messages: [message(1, 100), message(1, 102)], events: [], newChatPts: 1, contiguous: SeqRange(100, 102))
    try store.applyChat(chatId: 1, messages: [message(1, 25)], events: [], newChatPts: nil)
    try store.applyChat(chatId: 2, messages: [message(2, 101)], events: [], newChatPts: nil)
    let missing = try store.historyTargetWindow(chatId: 1, seq: 101)
    #expect(missing.floor == 100 && missing.count == 2 && missing.countFromTarget == 1 && !missing.containsTarget)
    let isolated = try store.historyTargetWindow(chatId: 1, seq: 25)
    #expect(isolated.floor == 100 && isolated.count == 2 && isolated.countFromTarget == 3 && isolated.containsTarget)
  }
}
