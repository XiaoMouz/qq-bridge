import Foundation
import Testing
@testable import BetterChat

@MainActor
private final class HistoryPageReplies: ChatHistoryPagingService {
  var count = 60
  var localFailure = false
  private(set) var requests: [UInt32] = []
  private var replies: [Int: CheckedContinuation<Int, any Error>] = [:]
  func localCount() throws -> Int {
    if localFailure { throw URLError(.cannotOpenFile) }
    return count
  }
  func loadOlder(limit: UInt32) async throws -> Int {
    let index = requests.count
    requests.append(limit)
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }
  func wait(_ count: Int) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while requests.count < count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(requests.count == count)
  }
  func finish(_ index: Int, count: Int) { replies.removeValue(forKey: index)?.resume(returning: count) }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct ChatHistoryPaginationTests {
  @Test func serverEndDoesNotHideUndisplayedLocalHistory() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    service.count = 150
    model.recordOlderPage(0)
    await model.load(using: service)?.value
    #expect(model.reachedStart && model.limit == 120)
    await model.load(using: service)?.value
    #expect(model.limit == 180)
    #expect(model.load(using: service) == nil && service.requests.isEmpty)
  }

  @Test func explicitRetryCanRecoverFromNewlyAvailableLocalHistory() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    let first = model.load(using: service)
    await service.wait(1); service.fail(0); await first?.value
    service.count = 100
    #expect(model.load(using: service) == nil && model.limit == 60)
    await model.load(using: service, retry: true)?.value
    #expect(model.error == nil && model.limit == 120 && service.requests.count == 1)
  }

  @Test func localPagesExpandBeforeNetworkAndZeroMarksStart() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    service.count = 150
    await model.load(using: service)?.value
    #expect(model.limit == 120 && service.requests.isEmpty && !model.isLoading)
    await model.load(using: service)?.value
    #expect(model.limit == 180 && service.requests.isEmpty)
    let last = model.load(using: service)
    await service.wait(1)
    #expect(model.isLoading && service.requests == [60])
    service.finish(0, count: 0); await last?.value
    await model.load(using: service)?.value
    #expect(model.reachedStart && model.limit == 180 && service.requests.count == 1)
  }

  @Test func failurePreservesWindowAndRequiresExplicitRetry() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    model.reveal(through: 240)
    let first = model.load(using: service)
    await service.wait(1); service.fail(0); await first?.value
    #expect(model.limit == 240 && model.error == "加载超时，请重试" && !model.reachedStart && !model.isLoading)
    await model.load(using: service)?.value
    #expect(service.requests.count == 1)
    let retry = model.load(using: service, retry: true)
    let duplicate = model.load(using: service, retry: true)
    await service.wait(2)
    #expect(model.error == nil && model.isLoading)
    service.finish(1, count: 20); await retry?.value; await duplicate?.value
    #expect(model.limit == 260 && !model.isLoading && !model.reachedStart && model.error == nil)
  }

  @Test func localReadFailureDoesNotPretendHistoryIsExhausted() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    service.localFailure = true
    await model.load(using: service)?.value
    #expect(model.error != nil && !model.reachedStart && service.requests.isEmpty)
    service.localFailure = false; service.count = 100
    await model.load(using: service, retry: true)?.value
    #expect(model.error == nil && model.limit == 120 && service.requests.isEmpty)
  }

  @Test(arguments: [false, true]) func cancelledReplyCannotAffectNextPage(fail: Bool) async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    let first = model.load(using: service)
    await service.wait(1)
    model.cancel()
    #expect(!model.isLoading)
    let next = model.resume(using: service)
    #expect(model.resume(using: service) == nil)
    await service.wait(2)
    if fail { service.fail(0) } else { service.finish(0, count: 0) }
    await first?.value
    #expect(model.isLoading && !model.reachedStart && model.error == nil && model.limit == 60)
    service.finish(1, count: 30); await next?.value
    #expect(model.limit == 90 && !model.isLoading)
  }

  @Test func newMessagesDuringFetchRemainIncludedAndTrimResetsBoundary() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    let first = model.load(using: service)
    await service.wait(1)
    model.includeNewMessages(5)
    service.finish(0, count: 60); await first?.value
    #expect(model.limit == 125)
    let next = model.load(using: service)
    await service.wait(2); service.finish(1, count: 0); await next?.value
    #expect(model.reachedStart)
    model.trim()
    #expect(model.limit == 60 && !model.reachedStart && model.error == nil)
    let reload = model.load(using: service)
    await service.wait(3); service.finish(2, count: 10); await reload?.value
    #expect(model.limit == 70)
  }

  @Test func jumpAndTrimInvalidatePendingScrollPages() async {
    let service = HistoryPageReplies(), model = ChatHistoryPagination()
    let first = model.load(using: service)
    await service.wait(1)
    model.prepareForJump(); model.reveal(through: 500)
    service.finish(0, count: 60); await first?.value
    #expect(model.limit == 500 && !model.isLoading)
    model.recordOlderPage(500)
    #expect(model.limit == 1000)
    let next = model.load(using: service)
    await service.wait(2)
    model.trim(); service.fail(1); await next?.value
    #expect(model.limit == 60 && !model.reachedStart && !model.isLoading && model.error == nil)
  }
}
