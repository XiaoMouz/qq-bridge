import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class StorageSummaryReplies<Value: Sendable> {
  var count = 0
  var replies: [Int: CheckedContinuation<Value, any Error>] = [:]
  func fetch() async throws -> Value {
    let index = count
    return try await withCheckedThrowingContinuation { replies[index] = $0; count += 1 }
  }
  func finish(_ index: Int, _ value: Value) { replies.removeValue(forKey: index)?.resume(returning: value) }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct MacStorageSummaryTests {
  private func wait(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition())
  }

  @Test func failedInitialListRetriesWithoutDuplicateRequestsAndAcceptsEmptyResult() async {
    let replies = StorageSummaryReplies<[MacStorageChat]>()
    let model = MacStorageSummaryModel(fetch: replies.fetch)
    let first = model.reload(), duplicate = model.reload(); model.start()
    await wait { replies.count == 1 }
    replies.fail(0); await first.value; await duplicate.value
    #expect(model.value == nil && model.error == "加载超时，请重试" && !model.isLoading)
    model.start(); #expect(!model.isLoading)
    let retry = model.reload(); await wait { replies.count == 2 }
    replies.finish(1, []); await retry.value
    #expect(model.value?.isEmpty == true && model.error == nil && !model.isLoading)
    model.start(); #expect(!model.isLoading)
  }

  @Test func failedDetailRefreshKeepsSummaryAndTypeLinksUntilSuccess() async {
    let replies = StorageSummaryReplies<Qqbridge_V1_GetChatStorageResponse>()
    let model = MacStorageSummaryModel(fetch: replies.fetch)
    var detail = Qqbridge_V1_GetChatStorageResponse()
    detail.summary.logicalBytes = 1024; detail.summary.blobCount = 2
    var kind = Qqbridge_V1_KindStorage(); kind.kind = .image; kind.logicalBytes = 1024; kind.count = 2
    detail.kinds = [kind]
    let first = model.reload(); await wait { replies.count == 1 }
    replies.finish(0, detail); await first.value
    let refresh = model.reload(); await wait { replies.count == 2 }
    #expect(model.value == detail && model.isLoading)
    replies.fail(1); await refresh.value
    #expect(model.value == detail && model.error != nil && !model.isLoading)
    let retry = model.reload(); await wait { replies.count == 3 }
    replies.finish(2, Qqbridge_V1_GetChatStorageResponse()); await retry.value
    #expect(model.value?.summary.blobCount == 0 && model.value?.kinds.isEmpty == true && model.error == nil)
  }

  @Test(arguments: [false, true]) func returningBeforeFirstLoadRejectsLateResponse(fails: Bool) async {
    let replies = StorageSummaryReplies<Qqbridge_V1_GetChatStorageResponse>()
    let model = MacStorageSummaryModel(fetch: replies.fetch)
    let old = model.reload(); await wait { replies.count == 1 }
    model.cancel(); model.start(); await wait { replies.count == 2 }
    var current = Qqbridge_V1_GetChatStorageResponse(); current.summary.blobCount = 5
    replies.finish(1, current); await wait { !model.isLoading }
    if fails { replies.fail(0) } else { replies.finish(0, Qqbridge_V1_GetChatStorageResponse()) }
    await old.value
    #expect(model.value == current && model.error == nil && !model.isLoading)
  }

  @Test func returningFromCategoryKeepsSnapshotAndCancelledRefreshCannotReplaceIt() async {
    let replies = StorageSummaryReplies<[MacStorageChat]>()
    let model = MacStorageSummaryModel(fetch: replies.fetch)
    let chat = MacStorageChat(id: 153, bytes: 1024, count: 2, scene: .group, peerID: 521409608)
    let initial = model.reload(); await wait { replies.count == 1 }
    replies.finish(0, [chat]); await initial.value
    let old = model.reload(); await wait { replies.count == 2 }
    model.cancel(); model.start()
    #expect(!model.isLoading && model.value?.first?.id == 153 && replies.count == 2)
    let refresh = model.reload(); await wait { replies.count == 3 }
    replies.finish(1, []); await old.value
    #expect(model.isLoading && model.value?.first?.id == 153)
    replies.finish(2, []); await refresh.value
    #expect(model.value?.isEmpty == true && !model.isLoading)
  }
}
