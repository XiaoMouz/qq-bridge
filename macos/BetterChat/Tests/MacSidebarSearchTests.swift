import Foundation
@testable import QQBridgeKit
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor
private final class EmptyDialogs: MacDialogSource {
  var items: [DialogItem] { [] }
}

@MainActor
private final class SearchService: MacSearchService {
  enum Request: Equatable { case search(String), open(Int64) }
  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
  var contacts: [Qqbridge_V1_Peer] = []
  var requests: [Request] = []
  var searches: [String: CheckedContinuation<[Qqbridge_V1_Message], any Error>] = [:]
  var opens: [Int64: CheckedContinuation<Int64, any Error>] = [:]
  private var unread: [Request] = []
  private var requestWaiter: CheckedContinuation<Request, Never>?

  func localContacts() -> [Qqbridge_V1_Peer] { contacts }
  func requestAvatar(for peer: Qqbridge_V1_Peer, in avatars: AvatarBook) {}
  func searchMessages(_ term: String, limit: Int) async throws -> [Qqbridge_V1_Message] {
    try await withCheckedThrowingContinuation {
      searches[term] = $0
      record(.search(term))
    }
  }
  func openChat(with peer: Qqbridge_V1_Peer) async throws -> Int64 {
    try await withCheckedThrowingContinuation {
      opens[peer.peerID] = $0
      record(.open(peer.peerID))
    }
  }
  private func record(_ request: Request) {
    requests.append(request)
    if let waiter = requestWaiter {
      requestWaiter = nil
      waiter.resume(returning: request)
    } else { unread.append(request) }
  }
  func nextRequest() async -> Request {
    if !unread.isEmpty { return unread.removeFirst() }
    return await withCheckedContinuation { requestWaiter = $0 }
  }
  func finishSearch(_ term: String, messages: [Qqbridge_V1_Message] = [], failure: String? = nil) {
    guard let pending = searches.removeValue(forKey: term) else { Issue.record("缺少挂起的搜索请求"); return }
    if let failure { pending.resume(throwing: Failure(failure)) }
    else { pending.resume(returning: messages) }
  }
  func finishOpen(_ id: Int64, chat: Int64 = 41, failure: String? = nil) {
    guard let pending = opens.removeValue(forKey: id) else { Issue.record("缺少挂起的打开请求"); return }
    if let failure { pending.resume(throwing: Failure(failure)) }
    else { pending.resume(returning: chat) }
  }
  func cancelOpen(_ id: Int64) {
    opens.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}

@Suite(.serialized)
@MainActor
struct MacSidebarSearchTests {
  @Test func unavailableDoesNotIncorrectlyRequestQQLogin() {
    let failure = APIError(code: .unavailable, message: "The network connection was lost.")
    #expect(LoadState.describe(failure) == "服务暂不可用，请检查连接后重试")
  }
  private func fixture() -> (SearchService, EmptyDialogs, MacSidebarSearchViewModel) {
    let service = SearchService()
    var peer = Qqbridge_V1_Peer()
    peer.kind = .user
    peer.peerID = 900001
    peer.name = "验收联系人"
    service.contacts = [peer]
    let dialogs = EmptyDialogs()
    return (service, dialogs, MacSidebarSearchViewModel(service: service, dialogs: dialogs))
  }
  private func settled(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("响应后的状态未收尾")
  }
  private func message(_ seq: Int64) -> Qqbridge_V1_Message {
    var result = Qqbridge_V1_Message()
    result.chatID = 41
    result.seq = seq
    return result
  }

  @Test func failedContactRetryOpensSameContactAndKeepsSearchResults() async {
    let (service, dialogs, model) = fixture()
    defer { _ = dialogs }
    model.update(query: "验收")
    #expect(await service.nextRequest() == .search("验收"))
    service.finishSearch("验收", messages: [message(1)])
    await settled { !model.isLoading }
    model.select(.contact("1:900001"))
    #expect(await service.nextRequest() == .open(900001))
    service.finishOpen(900001, failure: "打开失败")
    await settled { model.error != nil }
    #expect(model.retryTitle == "重新打开会话")
    model.retry()
    model.retry()
    let retried = await service.nextRequest()
    #expect(retried == .open(900001))
    #expect(model.messages.map(\.seq) == [1])
    #expect(model.selected == .contact("1:900001"))
    if case .open(let peer) = retried { service.finishOpen(peer) }
    else { service.finishSearch("验收") }
    await settled { model.error == nil && !model.isLoading }
  }

  @Test func searchAndContactFailuresHaveIndependentRetries() async {
    let (service, dialogs, model) = fixture()
    defer { _ = dialogs }
    var routes: [MacSidebarRoute] = []
    model.route = { routes.append($0) }
    model.update(query: "验收")
    #expect(await service.nextRequest() == .search("验收"))
    model.select(.contact("1:900001"))
    #expect(await service.nextRequest() == .open(900001))
    service.finishOpen(900001, failure: "联系人打开失败")
    await settled { model.error != nil }
    service.finishSearch("验收", failure: "历史搜索失败")
    await settled { !model.isLoading }
    #expect(model.error?.contains("联系人打开失败") == true)
    model.retry()
    #expect(!model.canRetry)
    model.retry()
    let firstRetry = await service.nextRequest()
    #expect(firstRetry == .open(900001))
    guard case .open(let peer) = firstRetry else {
      service.finishSearch("验收")
      return
    }
    service.finishOpen(peer)
    await settled { routes == [.chat(41)] }
    #expect(model.error?.contains("历史搜索失败") == true)
    #expect(model.retryTitle == "重试搜索")
    model.retry()
    #expect(await service.nextRequest() == .search("验收"))
    service.finishSearch("验收", messages: [message(2)])
    await settled { !model.isLoading }
    #expect(model.error == nil && model.messages.map(\.seq) == [2])
  }

  @Test func changedQueryRejectsLateSearchFailure() async {
    let (service, dialogs, model) = fixture()
    defer { _ = dialogs }
    model.update(query: "旧查询")
    #expect(await service.nextRequest() == .search("旧查询"))
    model.update(query: "新查询")
    #expect(await service.nextRequest() == .search("新查询"))
    service.finishSearch("新查询", messages: [message(3)])
    await settled { !model.isLoading }
    service.finishSearch("旧查询", failure: "迟到错误")
    for _ in 0..<100 { await Task.yield() }
    #expect(model.term == "新查询" && model.error == nil)
    #expect(model.messages.map(\.seq) == [3])
  }

  @Test func leavingSearchRejectsLateContactFailure() async {
    let (service, dialogs, model) = fixture()
    defer { _ = dialogs }
    var routes: [MacSidebarRoute] = []
    model.route = { routes.append($0) }
    model.update(query: "验收")
    #expect(await service.nextRequest() == .search("验收"))
    service.finishSearch("验收")
    await settled { !model.isLoading }
    model.select(.contact("1:900001"))
    #expect(await service.nextRequest() == .open(900001))
    model.cancelPendingOpen()
    service.finishOpen(900001, failure: "过期的打开失败")
    for _ in 0..<100 { await Task.yield() }
    #expect(model.error == nil && routes.isEmpty)
    #expect(model.term == "验收")
    #expect(model.groups.flatMap(\.results).allSatisfy { !$0.busy })
  }

  @Test func clearingQueryDiscardsFailedContactAndDisablesStaleRetry() async {
    let (service, dialogs, model) = fixture()
    defer { _ = dialogs }
    #expect(MacAppDelegate.runsStateTests)
    model.update(query: "验收")
    #expect(await service.nextRequest() == .search("验收"))
    service.finishSearch("验收")
    await settled { !model.isLoading }
    model.select(.contact("1:900001"))
    #expect(await service.nextRequest() == .open(900001))
    service.finishOpen(900001, failure: "打开失败")
    await settled { model.error != nil }
    model.cancel()
    let count = service.requests.count
    model.retry()
    for _ in 0..<100 { await Task.yield() }
    #expect(service.requests.count == count)
    #expect(model.term.isEmpty && model.groups.isEmpty && model.error == nil)
    #expect(!model.canRetry && model.selected == nil)
  }

  @Test func cancelledOpenClearsRowSpinnerWithoutReportingFailure() async {
    let (service, dialogs, model) = fixture()
    defer { _ = dialogs }
    model.update(query: "验收")
    #expect(await service.nextRequest() == .search("验收"))
    service.finishSearch("验收")
    await settled { !model.isLoading }
    model.select(.contact("1:900001"))
    #expect(await service.nextRequest() == .open(900001))
    #expect(model.groups.flatMap(\.results).contains { $0.busy })
    service.cancelOpen(900001)
    await settled { model.groups.flatMap(\.results).allSatisfy { !$0.busy } }
    #expect(model.error == nil && !model.canRetry)
    model.select(.contact("1:900001"))
    #expect(await service.nextRequest() == .open(900001))
    service.finishOpen(900001)
    await settled { model.groups.flatMap(\.results).allSatisfy { !$0.busy } }
  }
}
