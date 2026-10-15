import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor
private final class HistoryService: MacChatHistoryService {
  struct Request: Equatable { let chatID: Int64; let query: String; var before: Qqbridge_V1_SearchCursor? = nil }
  struct Failure: LocalizedError { var errorDescription: String? { "测试网络错误" } }
  var requests: [Request] = []
  var pending: [Int: CheckedContinuation<Qqbridge_V1_SearchMessagesResponse, any Error>] = [:]
  func search(chatID: Int64, query: String, before: Qqbridge_V1_SearchCursor?) async throws -> Qqbridge_V1_SearchMessagesResponse {
    let index = requests.count
    return try await withCheckedThrowingContinuation { continuation in
      pending[index] = continuation
      requests.append(Request(chatID: chatID, query: query, before: before))
    }
  }
  func finish(_ index: Int, messages: [Qqbridge_V1_Message] = [], fails: Bool = false, next: Qqbridge_V1_SearchCursor? = nil) {
    guard let continuation = pending.removeValue(forKey: index) else { Issue.record("缺少待完成的查询"); return }
    if fails { continuation.resume(throwing: Failure()) }
    else {
      var page = Qqbridge_V1_SearchMessagesResponse(); page.messages = messages
      if let next { page.next = next }
      continuation.resume(returning: page)
    }
  }
}

@Suite(.serialized)
@MainActor
struct MacChatHistoryTests {
  private func settle(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("查询状态未在期限内完成")
  }
  private func message(_ chat: Int64, _ seq: Int64) -> Qqbridge_V1_Message {
    var value = Qqbridge_V1_Message()
    value.chatID = chat
    value.seq = seq
    return value
  }

  @Test func paginationPreservesResultsRetriesAndDeduplicates() async {
    let service = HistoryService(); let model = MacChatHistoryViewModel(chatID: 153, service: service)
    var cursor = Qqbridge_V1_SearchCursor(); cursor.chatID = 153; cursor.seq = 2; cursor.time = 100
    model.updateQuery("分页"); model.search()
    await settle { service.requests.count == 1 }
    service.finish(0, messages: [message(153, 3), message(153, 2)], next: cursor)
    await settle { !model.isSearching }
    model.loadMore(); model.loadMore()
    await settle { service.requests.count == 2 }
    #expect(service.requests[1].before == cursor && service.requests[1].query == "分页")
    service.finish(1, fails: true)
    await settle { !model.isLoadingMore }
    #expect(model.results.count == 2 && model.moreError != nil && model.next == cursor)
    model.loadMore()
    await settle { service.requests.count == 3 }
    service.finish(2, messages: [message(153, 2), message(154, 1), message(153, 1)])
    await settle { !model.isLoadingMore }
    #expect(model.results.map(\.seq) == [3, 2, 1] && model.moreError == nil && model.next == nil)
  }

  @Test func newQueryRejectsLatePageAndRepeatedCursorCanRetry() async {
    let service = HistoryService(); let model = MacChatHistoryViewModel(chatID: 153, service: service)
    var cursor = Qqbridge_V1_SearchCursor(); cursor.chatID = 153; cursor.seq = 2; cursor.time = 100
    model.updateQuery("旧"); model.search()
    await settle { service.requests.count == 1 }
    service.finish(0, messages: [message(153, 2)], next: cursor)
    await settle { !model.isSearching }
    model.loadMore()
    await settle { service.requests.count == 2 }
    service.finish(1, messages: [message(153, 2)], next: cursor)
    await settle { !model.isLoadingMore }
    #expect(model.moreError != nil && model.results.count == 1)
    model.loadMore()
    await settle { service.requests.count == 3 }
    model.updateQuery("新"); model.search()
    await settle { service.requests.count == 4 }
    service.finish(3, messages: [message(153, 20)])
    await settle { !model.isSearching }
    service.finish(2, messages: [message(153, 1)])
    for _ in 0..<20 { await Task.yield() }
    #expect(model.results.map(\.seq) == [20] && model.searched == "新" && model.next == nil && model.moreError == nil)
  }

  @Test func requestAndResultsStayWithinSelectedConversation() async {
    let service = HistoryService()
    let model = MacChatHistoryViewModel(chatID: 153, service: service)
    model.updateQuery("  测试 \n")
    model.search()
    await settle { service.requests.count == 1 }
    #expect(service.requests == [.init(chatID: 153, query: "测试")])
    service.finish(0, messages: [message(154, 8), message(153, 9)])
    await settle { !model.isSearching }
    #expect(model.results.map(\.seq) == [9])
  }

  @Test func newerQueryWinsEvenWhenOlderResponseArrivesLast() async {
    let service = HistoryService()
    let model = MacChatHistoryViewModel(chatID: 153, service: service)
    model.updateQuery("旧"); model.search()
    await settle { service.requests.count == 1 }
    model.updateQuery("新"); model.search()
    await settle { service.requests.count == 2 }
    service.finish(1, messages: [message(153, 20)])
    await settle { model.searched == "新" }
    service.finish(0, messages: [message(153, 10)])
    for _ in 0..<20 { await Task.yield() }
    #expect(model.searched == "新")
    #expect(model.results.map(\.seq) == [20])
  }

  @Test func clearingQueryDoesNotResurrectOldResults() async {
    let service = HistoryService()
    let model = MacChatHistoryViewModel(chatID: 153, service: service)
    model.updateQuery("清除"); model.search()
    await settle { service.requests.count == 1 }
    model.updateQuery("")
    service.finish(0, messages: [message(153, 1)])
    for _ in 0..<20 { await Task.yield() }
    #expect(!model.isSearching && model.results.isEmpty && model.searched == nil)
    #expect(!model.canSearch)
  }

  @Test func failureCanRetryWithoutChangingConversation() async {
    let service = HistoryService()
    let model = MacChatHistoryViewModel(chatID: 32, service: service)
    model.updateQuery("重试"); model.search()
    await settle { service.requests.count == 1 }
    service.finish(0, fails: true)
    await settle { model.error != nil }
    model.search()
    await settle { service.requests.count == 2 }
    service.finish(1, messages: [message(32, 2)])
    await settle { !model.isSearching }
    #expect(model.error == nil && model.results.count == 1)
    #expect(service.requests.allSatisfy { $0.chatID == 32 })
  }

  @Test func leavingPageIgnoresLateFailureAndInvalidIDNeverSearchesGlobally() async {
    let service = HistoryService()
    let model = MacChatHistoryViewModel(chatID: 153, service: service)
    model.updateQuery("离开"); model.search()
    await settle { service.requests.count == 1 }
    model.cancel()
    service.finish(0, fails: true)
    let invalid = MacChatHistoryViewModel(chatID: 0, service: service)
    invalid.updateQuery("不可变成全局搜索"); invalid.search()
    for _ in 0..<20 { await Task.yield() }
    #expect(model.error == nil && !model.isSearching)
    #expect(service.requests.count == 1)
    #expect(!invalid.canSearch)
  }
}
