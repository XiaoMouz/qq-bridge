import Foundation
import Testing
@testable import BetterChat

@MainActor private final class GroupListReplies: MacGroupListService {
  typealias Item = String
  private(set) var count = 0
  private var replies: [Int: CheckedContinuation<[String], any Error>] = [:]

  func load() async throws -> [String] {
    let index = count
    count += 1
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }
  func waitForRequests(_ expected: Int) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while count < expected, ContinuousClock.now < deadline { await Task.yield() }
    #expect(count == expected)
  }
  func finish(_ index: Int, _ items: [String]) { replies.removeValue(forKey: index)?.resume(returning: items) }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct MacGroupListTests {
  @Test func firstFailureRequiresExplicitRetryAndEmptySuccessIsLoaded() async {
    let replies = GroupListReplies()
    let model = MacGroupListViewModel(service: replies)
    let first = model.load()
    await replies.waitForRequests(1)
    replies.fail(0)
    await first.value
    #expect(model.error == "加载超时，请重试" && !model.hasLoaded && !model.isLoading)
    model.start()
    #expect(replies.count == 1)
    let retry = model.load()
    await replies.waitForRequests(2)
    replies.finish(1, [])
    await retry.value
    #expect(model.hasLoaded && model.items.isEmpty && model.error == nil && !model.isLoading)
  }

  @Test func refreshFailureKeepsContentUntilSuccessfulReplacement() async {
    let replies = GroupListReplies()
    let model = MacGroupListViewModel(service: replies)
    let first = model.load()
    await replies.waitForRequests(1)
    replies.finish(0, ["old"])
    await first.value
    let refresh = model.load()
    await replies.waitForRequests(2)
    #expect(model.items == ["old"] && model.isLoading)
    replies.fail(1)
    await refresh.value
    #expect(model.items == ["old"] && model.hasLoaded && model.error != nil && !model.isLoading)
    let retry = model.load()
    await replies.waitForRequests(3)
    replies.finish(2, ["new"])
    await retry.value
    #expect(model.items == ["new"] && model.error == nil)
  }

  @Test func overlappingRefreshAndInitialLoadShareOneRequest() async {
    let replies = GroupListReplies()
    let model = MacGroupListViewModel(service: replies)
    let first = model.load()
    let duplicate = model.load()
    model.start()
    await replies.waitForRequests(1)
    replies.finish(0, ["one"])
    await first.value
    await duplicate.value
    #expect(replies.count == 1 && model.items == ["one"] && !model.isLoading)
  }

  @Test func lateSuccessAfterLeavingDoesNotReplaceNewResult() async {
    await verifyLateReply(fails: false)
  }

  @Test func lateFailureAfterLeavingDoesNotHideNewResult() async {
    await verifyLateReply(fails: true)
  }

  @Test func returningFromDetailPreservesLoadedSnapshot() async {
    let replies = GroupListReplies()
    let model = MacGroupListViewModel(service: replies)
    let request = model.load()
    await replies.waitForRequests(1)
    replies.finish(0, ["kept"])
    await request.value
    model.cancel()
    model.start()
    #expect(replies.count == 1 && model.items == ["kept"] && !model.isLoading)
    let refresh = model.load()
    await replies.waitForRequests(2)
    replies.finish(1, [])
    await refresh.value
    #expect(model.items.isEmpty && model.hasLoaded)
  }

  private func verifyLateReply(fails: Bool) async {
    let replies = GroupListReplies()
    let model = MacGroupListViewModel(service: replies)
    let old = model.load()
    await replies.waitForRequests(1)
    model.cancel()
    #expect(!model.isLoading)
    let current = model.load()
    await replies.waitForRequests(2)
    replies.finish(1, ["current"])
    await current.value
    if fails { replies.fail(0) } else { replies.finish(0, ["stale"]) }
    await old.value
    #expect(model.items == ["current"] && model.error == nil && !model.isLoading)
  }
}
