import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class SharedMediaReplies: MacSharedMediaService {
  struct Request { let query: MacSharedMediaQuery; let before: Int64; let offset: Int32 }
  var requests: [Request] = []
  private var pending: [Int: CheckedContinuation<Qqbridge_V1_ListSharedMediaResponse, any Error>] = [:]
  func page(query: MacSharedMediaQuery, before: Int64, offset: Int32) async throws -> Qqbridge_V1_ListSharedMediaResponse {
    let index = requests.count
    requests.append(Request(query: query, before: before, offset: offset))
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }
  func finish(_ index: Int, _ items: [Qqbridge_V1_SharedMedia], before: Int64 = 0, offset: Int32 = 0) {
    var result = Qqbridge_V1_ListSharedMediaResponse()
    result.items = items; result.nextBeforeSeq = before; result.nextOffset = offset
    pending.removeValue(forKey: index)?.resume(returning: result)
  }
  func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct MacSharedMediaTests {
  private let newest = MacSharedMediaQuery(files: false, sort: "time_desc")
  private func item(_ seq: Int64, ord: UInt32 = 0, sha: String = "") -> Qqbridge_V1_SharedMedia {
    var result = Qqbridge_V1_SharedMedia()
    result.seq = seq; result.kind = .image
    result.segment.image.media.ord = ord
    result.segment.image.media.sha256 = sha
    return result
  }
  private func settle(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition())
  }

  @Test func switchingTypeIgnoresLateOldResponseAndStartsFreshCursor() async {
    let service = SharedMediaReplies()
    let subject = MacSharedMediaViewModel(service: service)
    subject.select(newest)
    await settle { service.requests.count == 1 }
    let files = MacSharedMediaQuery(files: true, sort: "time_desc")
    subject.select(files)
    await settle { service.requests.count == 2 }
    service.finish(1, [])
    await settle { !subject.isLoading }
    service.finish(0, [item(90)], before: 90)
    for _ in 0..<20 { await Task.yield() }
    #expect(subject.query == files && subject.items.isEmpty && !subject.hasMore && subject.error == nil)
    #expect(service.requests[1].before == 0 && service.requests[1].offset == 0)
  }

  @Test func switchingSortIgnoresOldFailureAndUsesOffsetPagination() async {
    let service = SharedMediaReplies()
    let model = MacSharedMediaViewModel(service: service)
    model.select(newest)
    await settle { service.requests.count == 1 }
    let query = MacSharedMediaQuery(files: false, sort: "size_desc")
    model.select(query)
    await settle { service.requests.count == 2 }
    service.finish(1, [item(2)], offset: 80)
    await settle { !model.isLoading }
    service.fail(0)
    let next = model.loadMore()
    await settle { service.requests.count == 3 }
    #expect(service.requests[2].offset == 80 && service.requests[2].before == 0)
    service.finish(2, [item(1)])
    await next?.value
    #expect(model.error == nil && model.items.map(\.seq) == [2, 1] && !model.hasMore)
  }

  @Test func firstFailureAndEmptyIntermediatePageRemainRetryable() async {
    let service = SharedMediaReplies(), model: MacSharedMediaViewModel
    model = MacSharedMediaViewModel(service: service)
    model.select(newest)
    await settle { service.requests.count == 1 }
    service.fail(0); await settle { !model.isLoading }
    #expect(model.error == "加载超时，请重试" && model.hasMore && !model.hasLoaded)
    model.select(newest)
    #expect(service.requests.count == 1)
    let retry = model.loadMore()
    await settle { service.requests.count == 2 }
    service.finish(1, [], before: 80); await retry?.value
    #expect(model.items.isEmpty && model.hasLoaded && model.hasMore && model.error == nil)
    let next = model.loadMore()
    await settle { service.requests.count == 3 }
    #expect(service.requests[2].before == 80)
    service.finish(2, [item(70)]); await next?.value
    #expect(!model.hasMore && model.items.map(\.seq) == [70])
  }

  @Test func failedNextPageKeepsItemsAndRetriesSameCursorWithoutAutomaticLoop() async {
    let service = SharedMediaReplies(), model: MacSharedMediaViewModel
    model = MacSharedMediaViewModel(service: service)
    model.select(newest)
    await settle { service.requests.count == 1 }
    service.finish(0, [item(100)], before: 100); await settle { !model.isLoading }
    let next = model.loadMore()
    #expect(model.loadMore() == nil)
    await settle { service.requests.count == 2 }
    service.fail(1); await next?.value
    #expect(model.items.map(\.seq) == [100] && model.hasMore && model.error != nil)
    model.reached(item(100)); #expect(service.requests.count == 2)
    let retry = model.loadMore()
    await settle { service.requests.count == 3 }
    #expect(service.requests[2].before == service.requests[1].before)
    service.finish(2, [item(99)]); await retry?.value
    #expect(model.items.map(\.seq) == [100, 99] && model.error == nil)
  }

  @Test func duplicateMediaRefreshesMetadataButPreservesDifferentOrdinals() async {
    let service = SharedMediaReplies(), model: MacSharedMediaViewModel
    model = MacSharedMediaViewModel(service: service)
    model.select(newest)
    await settle { service.requests.count == 1 }
    service.finish(0, [item(100), item(100)], before: 100); await settle { !model.isLoading }
    let next = model.loadMore()
    await settle { service.requests.count == 2 }
    service.finish(1, [item(100, sha: "ready"), item(100, ord: 1), item(99)]); await next?.value
    #expect(model.items.count == 3 && model.items[0].segment.image.media.sha256 == "ready")
    #expect(model.items[1].segment.image.media.ord == 1)
  }

  @Test func nonAdvancingSequenceAndOffsetDoNotSpinOrDiscardCursor() async {
    for query in [newest, MacSharedMediaQuery(files: true, sort: "sender")] {
      let service = SharedMediaReplies(), model: MacSharedMediaViewModel
      model = MacSharedMediaViewModel(service: service)
      model.select(query)
      await settle { service.requests.count == 1 }
      service.finish(0, [item(100)], before: 100, offset: 80); await settle { !model.isLoading }
      let next = model.loadMore()
      await settle { service.requests.count == 2 }
      service.finish(1, [item(99)], before: 100, offset: 80); await next?.value
      #expect(model.error == "分页未推进，请重试" && model.items.count == 1 && model.hasMore)
      model.reached(item(100)); #expect(service.requests.count == 2)
    }
  }

  @Test func cancellationRejectsLateDataAndReentryResumesUnfinishedPage() async {
    let service = SharedMediaReplies(), model: MacSharedMediaViewModel
    model = MacSharedMediaViewModel(service: service)
    model.select(newest)
    await settle { service.requests.count == 1 }
    model.cancel()
    model.select(newest)
    await settle { service.requests.count == 2 }
    service.finish(1, [item(2)]); await settle { !model.isLoading }
    service.finish(0, [item(3)], before: 3)
    for _ in 0..<20 { await Task.yield() }
    #expect(model.items.map(\.seq) == [2] && !model.hasMore && !model.isLoading)
  }
}
