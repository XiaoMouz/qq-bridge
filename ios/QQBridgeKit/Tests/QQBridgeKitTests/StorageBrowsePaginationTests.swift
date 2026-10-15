import Foundation
import Testing
@testable import QQBridgeKit

@Suite struct StorageBrowsePaginationTests {
  @Test func moreThanThreeHundredItemsUseStableFilteredPages() throws {
    let store = try LocalStore.inMemory()
    try store.db.write { db in
      for index in 0..<325 {
        let sha = String(format: "%064d", index)
        try db.execute(sql: "INSERT INTO mediaCache (sha256, size, createdAt, lastAccessAt, chatId) VALUES (?, 100, 1, 1, 153)", arguments: [sha])
        try db.execute(sql: "INSERT INTO mediaIndex (sha256, chatId, seq, kind) VALUES (?, 153, ?, 'file')", arguments: [sha, index + 1])
      }
      try db.execute(sql: "INSERT INTO mediaCache (sha256, size, createdAt, lastAccessAt, chatId) VALUES ('other-chat', 999, 1, 1, 154)")
      try db.execute(sql: "INSERT INTO mediaIndex (sha256, chatId, seq, kind) VALUES ('other-chat', 154, 1, 'file')")
    }
    #expect(try store.cacheItems(chatId: 153, kinds: [.file]).count == 300)
    var ids: [String] = []
    for offset in stride(from: 0, to: 360, by: 60) {
      ids += try store.cacheItems(chatId: 153, kinds: [.file], limit: 60, offset: offset).map(\.id)
    }
    #expect(ids.count == 325 && Set(ids).count == 325 && ids == ids.sorted())
    #expect(!ids.contains("other-chat"))
    #expect(try store.cacheItems(chatId: 153, kinds: [.file], limit: 60, offset: 360).isEmpty)
    #expect(try store.cacheItems(chatId: nil, kinds: [.audio], limit: 60, offset: 0).isEmpty)
  }
}
