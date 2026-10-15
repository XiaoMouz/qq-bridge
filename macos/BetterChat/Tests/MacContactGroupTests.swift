import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class ContactGroupReplies: MacContactGroupService {
  var requests: [CheckedContinuation<Qqbridge_V1_Dialog, any Error>] = []
  var deadlines: [CheckedContinuation<Void, any Error>] = []
  func load() async throws -> Qqbridge_V1_Dialog {
    try await withCheckedThrowingContinuation { requests.append($0) }
  }
  func wait() async throws { try await withCheckedThrowingContinuation { deadlines.append($0) } }
  func ready(_ count: Int) async {
    let limit = ContinuousClock.now + .seconds(3)
    while (requests.count < count || deadlines.count < count), ContinuousClock.now < limit { await Task.yield() }
    #expect(requests.count == count && deadlines.count == count)
  }
  func result(_ id: Int64) -> Qqbridge_V1_Dialog {
    var dialog = Qqbridge_V1_Dialog()
    dialog.chatID = id
    dialog.scene = .group
    return dialog
  }
}

@Suite(.serialized) @MainActor
struct MacContactGroupTests {
  @Test func failureRetriesAndSuccessfulReturnKeepsTheLoadedPage() async {
    let replies = ContactGroupReplies()
    let model = MacContactGroupViewModel(service: replies, waitForDeadline: { try await replies.wait() })
    let first = model.load()
    model.start()
    await replies.ready(1)
    replies.requests[0].resume(throwing: URLError(.notConnectedToInternet))
    await first.value
    replies.deadlines[0].resume()
    #expect(model.error != nil && !model.isLoading && model.dialog == nil)
    model.start()
    #expect(replies.requests.count == 1)
    let retry = model.load()
    await replies.ready(2)
    replies.requests[1].resume(returning: replies.result(153))
    await retry.value
    replies.deadlines[1].resume()
    model.cancel()
    model.start()
    #expect(model.dialog?.chatID == 153 && model.error == nil && !model.isLoading)
    #expect(replies.requests.count == 2)
  }

  @Test func deadlineRejectsLateSuccess() async { await timeout(lateFailure: false) }
  @Test func deadlineRejectsLateFailure() async { await timeout(lateFailure: true) }

  private func timeout(lateFailure: Bool) async {
    let replies = ContactGroupReplies()
    let model = MacContactGroupViewModel(service: replies, waitForDeadline: { try await replies.wait() })
    let old = model.load()
    await replies.ready(1)
    replies.deadlines[0].resume()
    let limit = ContinuousClock.now + .seconds(3)
    while model.isLoading, ContinuousClock.now < limit { await Task.yield() }
    #expect(model.error == "群会话同步超时，请重试" && model.dialog == nil)
    let retry = model.load()
    await replies.ready(2)
    replies.requests[1].resume(returning: replies.result(153))
    await retry.value
    replies.deadlines[1].resume()
    if lateFailure { replies.requests[0].resume(throwing: URLError(.timedOut)) }
    else { replies.requests[0].resume(returning: replies.result(999)) }
    await old.value
    #expect(model.dialog?.chatID == 153 && model.error == nil && !model.isLoading)
  }

  @Test func leavingWhileLoadingAllowsReturnAndIgnoresTheCancelledReply() async {
    let replies = ContactGroupReplies()
    let model = MacContactGroupViewModel(service: replies, waitForDeadline: { try await replies.wait() })
    let old = model.load()
    await replies.ready(1)
    model.cancel()
    replies.deadlines[0].resume()
    #expect(!model.isLoading && model.error == nil)
    let current = model.load()
    await replies.ready(2)
    replies.requests[0].resume(returning: replies.result(999))
    await old.value
    #expect(model.isLoading && model.dialog == nil)
    replies.requests[1].resume(returning: replies.result(153))
    await current.value
    replies.deadlines[1].resume()
    #expect(model.dialog?.chatID == 153 && model.error == nil)
  }
}
