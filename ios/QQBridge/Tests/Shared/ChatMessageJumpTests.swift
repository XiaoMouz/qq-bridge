import Foundation
import Testing
@testable import BetterChat

@MainActor
private final class JumpReplies: ChatMessageJumpService {
  var floor: Int64? = 100
  var count = 60
  var countFromTarget = 30
  var existing: Set<Int64> = []
  var localError = false
  var prepareAction: () async throws -> Void = {}
  private(set) var reads = 0
  private(set) var requests = 0
  private var replies: [Int: CheckedContinuation<Int, any Error>] = [:]
  func prepare() async throws { try await prepareAction() }

  func window(for seq: Int64) throws -> ChatJumpWindow {
    reads += 1
    if localError { throw URLError(.cannotOpenFile) }
    return ChatJumpWindow(floor: floor, count: count, countFromTarget: countFromTarget, containsTarget: existing.contains(seq))
  }
  func loadOlder() async throws -> Int {
    let index = requests; requests += 1
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }
  func finish(_ index: Int, count: Int) { replies.removeValue(forKey: index)?.resume(returning: count) }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@MainActor
private func waitForJump(_ condition: () -> Bool) async {
  let deadline = ContinuousClock.now + .seconds(3)
  while !condition(), ContinuousClock.now < deadline { await Task.yield() }
  #expect(condition())
}

@Suite(.serialized) @MainActor
struct ChatMessageJumpTests {
  @Test func firstScreenMustFinishBeforeMissingTargetIsDecided() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    var resume: CheckedContinuation<Void, Never>?
    service.prepareAction = { await withCheckedContinuation { resume = $0 } }
    var found = false
    let task = Task { await model.jump(to: 110, using: service, history: history) { _ in found = true } }
    await waitForJump { resume != nil }
    #expect(service.reads == 0 && model.failure == nil)
    service.existing = [110]
    resume?.resume()
    await waitForJump { service.reads > 0 }
    model.updateRendered([110], limit: history.limit)
    #expect(await task.value && found && model.failure == nil)
  }

  @Test func trimmedWindowCannotUseStaleRenderedTarget() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    service.existing = [110]; service.countFromTarget = 170
    history.reveal(through: 200)
    model.updateRendered([110], limit: 200)
    history.trim()
    var found: [Int64] = []
    let task = Task { await model.jump(to: 110, using: service, history: history) { found.append($0) } }
    await waitForJump { history.limit == 190 }
    #expect(found.isEmpty && service.requests == 0)
    model.updateRendered([110], limit: 60)
    await Task.yield()
    #expect(found.isEmpty && model.target == 110)
    model.updateRendered([110], limit: 190)
    #expect(await task.value && found == [110])
  }

  @Test func missingFailureCanBeDismissedWithoutRetryOrNavigation() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    #expect(await model.jump(to: 110, using: service, history: history) { _ in Issue.record("不存在不能滚动") } == false)
    #expect(model.failure != nil)
    model.dismissFailure()
    #expect(model.failure == nil && model.target == nil && service.requests == 0)
  }

  @Test func unknownInitialWindowFetchesEvenWithIsolatedLocalMessage() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    service.floor = nil; service.count = 1; service.existing = [25]
    history.recordOlderPage(0)
    let task = Task { await model.jump(to: 25, using: service, history: history) { _ in } }
    await waitForJump { service.requests == 1 }
    service.floor = 20; service.count = 30; service.finish(0, count: 30)
    await waitForJump { !history.reachedStart }
    model.updateRendered([25], limit: history.limit); #expect(await task.value)
    #expect(model.failure == nil && service.requests == 1)
  }

  @Test(arguments: [false, true]) func concurrentWindowResetIsRetryableNotHistoryEnd(clear: Bool) async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    let task = Task { await model.jump(to: 25, using: service, history: history) { _ in Issue.record("区间重置不能滚动") } }
    await waitForJump { service.requests == 1 }
    service.floor = clear ? nil : 200; service.finish(0, count: 0)
    #expect(await task.value == false)
    #expect(model.failure?.message == "历史记录范围已更新，请重试" && !history.reachedStart)
  }

  @Test func localTargetWaitsForObservedListInsteadOfPolling() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    service.existing = [110]; service.countFromTarget = 170
    var found: [Int64] = []
    let task = Task { await model.jump(to: 110, using: service, history: history) { found.append($0) } }
    await waitForJump { history.limit == 190 }
    #expect(found.isEmpty && service.requests == 0 && service.reads == 1)
    model.updateRendered([111], limit: history.limit)
    #expect(found.isEmpty && model.target == 110)
    model.updateRendered([110, 111], limit: history.limit)
    #expect(await task.value)
    #expect(found == [110] && model.target == nil && model.failure == nil)
  }

  @Test(arguments: [false, true]) func loadedTargetSupersedesOlderNetworkRequest(fail: Bool) async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    model.updateRendered([150], limit: history.limit)
    var found: [Int64] = []
    let old = Task { await model.jump(to: 50, using: service, history: history) { found.append($0) } }
    await waitForJump { service.requests == 1 }
    #expect(await model.jump(to: 150, using: service, history: history) { found.append($0) })
    if fail { service.fail(0) } else { service.finish(0, count: 500) }
    #expect(await old.value == false)
    #expect(found == [150] && model.failure == nil && model.target == nil && history.limit == 60)
  }

  @Test func oldFailureCannotClearNewSearchOrPublishError() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    var found: [Int64] = []
    let old = Task { await model.jump(to: 50, using: service, history: history) { found.append($0) } }
    await waitForJump { service.requests == 1 }
    let newer = Task { await model.jump(to: 25, using: service, history: history) { found.append($0) } }
    await waitForJump { service.requests == 2 }
    service.fail(0); #expect(await old.value == false)
    #expect(model.target == 25 && model.failure == nil && found.isEmpty)
    service.floor = 20; service.count = 90; service.existing = [25]; service.countFromTarget = 80
    service.finish(1, count: 30)
    await waitForJump { history.limit == 100 }
    model.updateRendered([25], limit: history.limit); #expect(await newer.value)
    #expect(found == [25])
  }

  @Test func cancelWhileWaitingForListReleasesRequestWithoutLateScroll() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    service.existing = [110]; service.countFromTarget = 80
    var found: [Int64] = []
    let task = Task { await model.jump(to: 110, using: service, history: history) { found.append($0) } }
    await waitForJump { history.limit == 100 }
    model.cancel()
    #expect(await task.value == false)
    model.updateRendered([110], limit: history.limit)
    #expect(found.isEmpty && model.target == nil && model.failure == nil)
  }

  @Test func cancelledCallerDoesNotCancelReplacement() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    let old = Task { await model.jump(to: 50, using: service, history: history) { _ in Issue.record("旧请求不应滚动") } }
    await waitForJump { service.requests == 1 }
    old.cancel()
    await waitForJump { model.target == nil }
    var found: [Int64] = []
    let next = Task { await model.jump(to: 25, using: service, history: history) { found.append($0) } }
    await waitForJump { service.requests == 2 }
    service.fail(0); #expect(await old.value == false)
    #expect(model.target == 25)
    model.cancel(); service.fail(1); #expect(await next.value == false)
    #expect(found.isEmpty && model.failure == nil)
  }

  @Test func localReadFailureAndMissingTargetRemainRetryable() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    service.localError = true
    #expect(await model.jump(to: 110, using: service, history: history) { _ in Issue.record("读取失败不能滚动") } == false)
    #expect(model.failure?.seq == 110 && !history.reachedStart && service.requests == 0)
    service.localError = false
    #expect(await model.jump(to: 110, using: service, history: history) { _ in Issue.record("不存在不能滚动") } == false)
    #expect(model.failure?.message == "这条消息已不存在或暂时不可用")
    model.updateRendered([110], limit: history.limit)
    var found: [Int64] = []
    #expect(await model.jump(to: 110, using: service, history: history) { found.append($0) })
    #expect(found == [110] && model.failure == nil)
  }

  @Test func remotePagesJoinIsolatedTargetAndUseActualWindowSize() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    service.existing = [25]
    var found: [Int64] = []
    let task = Task { await model.jump(to: 25, using: service, history: history) { found.append($0) } }
    await waitForJump { service.requests == 1 }
    service.floor = 50; service.count = 90; service.finish(0, count: 500)
    await waitForJump { service.requests == 2 }
    #expect(history.limit == 90 && found.isEmpty)
    service.floor = 20; service.count = 120; service.countFromTarget = 115; service.finish(1, count: 500)
    await waitForJump { history.limit == 135 }
    model.updateRendered([25], limit: history.limit); #expect(await task.value)
    #expect(found == [25] && history.limit == 135 && service.requests == 2)
  }

  @Test(arguments: [0, 60]) func remoteEndOrRepeatedPageStopsWithoutLoop(count: Int) async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    let task = Task { await model.jump(to: 25, using: service, history: history) { _ in Issue.record("未找到不能滚动") } }
    await waitForJump { service.requests == 1 }
    service.finish(0, count: count); #expect(await task.value == false)
    #expect(service.requests == 1 && history.limit == 60 && model.failure?.seq == 25)
    #expect(history.reachedStart == (count == 0))
  }

  @Test func listTimeoutIsNotReportedAsMissingAndCanRetry() async {
    let service = JumpReplies(), model = ChatMessageJump(renderTimeout: .milliseconds(10)), history = ChatHistoryPagination()
    service.existing = [110]
    #expect(await model.jump(to: 110, using: service, history: history) { _ in Issue.record("列表未显示不能滚动") } == false)
    #expect(model.failure?.message == "消息列表更新超时，请重试")
    model.updateRendered([110], limit: history.limit)
    #expect(await model.jump(to: 110, using: service, history: history) { _ in })
    #expect(model.failure == nil)
  }

  @Test func delayedRouteIsCancelledByNewTargetAndExplicitCancel() async {
    let service = JumpReplies(), model = ChatMessageJump(), history = ChatHistoryPagination()
    model.updateRendered([150], limit: history.limit)
    let old = Task { await model.jump(to: 50, delay: .seconds(30), using: service, history: history) { _ in Issue.record("旧路由不应滚动") } }
    await waitForJump { model.target == 50 }
    #expect(await model.jump(to: 150, using: service, history: history) { _ in })
    #expect(await old.value == false)
    let delayed = Task { await model.jump(to: 25, delay: .seconds(30), using: service, history: history) { _ in Issue.record("已取消路由不应滚动") } }
    await waitForJump { model.target == 25 }
    model.cancel(); #expect(await delayed.value == false)
    #expect(service.requests == 0 && model.failure == nil)
  }
}
