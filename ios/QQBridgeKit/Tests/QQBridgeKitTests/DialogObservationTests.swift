import Foundation
import QQBridgeProto
import Testing
@testable import QQBridgeKit

struct DialogObservationTests {
  @Test func watchesTheRequestedDialogEvenWhenItIsOutsideTheListWindow() async throws {
    let store = try LocalStore.inMemory()
    var recent = Qqbridge_V1_Dialog()
    recent.chatID = 10
    recent.topTime = 100
    try store.apply(dialog: recent, pts: 1)
    var stream = store.observeDialog(chatId: 153).makeAsyncIterator()
    let missing = try await stream.next()
    #expect(missing != nil && missing! == nil)
    var wanted = Qqbridge_V1_Dialog()
    wanted.chatID = 153
    wanted.topTime = 1
    try store.apply(dialog: wanted, pts: 2)
    let arrived = try await stream.next()
    #expect(arrived??.chatID == 153)
    #expect(try store.dialogs(limit: 1).map(\.chatID) == [10])
    wanted.pinned = true
    try store.apply(dialog: wanted, pts: 3)
    let updated = try await stream.next()
    #expect(updated??.pinned == true)
  }
}
