import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor
private final class AlbumPages: MacAlbumMediaService {
  private(set) var cursors: [String] = []
  private var replies: [Int: CheckedContinuation<Qqbridge_V1_ListGroupAlbumMediaResponse, any Error>] = [:]

  func page(after cursor: String) async throws -> Qqbridge_V1_ListGroupAlbumMediaResponse {
    let index = cursors.count
    cursors.append(cursor)
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }

  func waitForRequests(_ count: Int) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while cursors.count < count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(cursors.count == count)
  }

  func finish(_ index: Int, ids: [String], next: String = "", more: Bool = false) {
    var response = Qqbridge_V1_ListGroupAlbumMediaResponse()
    response.media = ids.map { id in
      var item = Qqbridge_V1_GroupAlbumMedia()
      item.id = id
      item.time = 1_700_000_000
      return item
    }
    response.albumName = "测试相册"
    response.nextCursor = next
    response.hasMore_p = more
    replies.removeValue(forKey: index)?.resume(returning: response)
  }

  func fail(_ index: Int) {
    replies.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut))
  }
}

@Suite(.serialized) @MainActor
struct MacAlbumMediaTests {
  @Test func emptyIntermediatePageDoesNotEndAlbum() async throws {
    let pages = AlbumPages()
    let model = MacAlbumMediaViewModel(service: pages)
    let first = try #require(model.loadMore())
    await pages.waitForRequests(1)
    pages.finish(0, ids: [], next: "page-2", more: true)
    await first.value
    #expect(model.media.isEmpty && model.hasLoaded && model.hasMore && model.error == nil)
    let next = try #require(model.loadMore())
    await pages.waitForRequests(2)
    pages.finish(1, ids: ["a"])
    await next.value
    #expect(pages.cursors == ["", "page-2"])
    #expect(model.media.map(\.id) == ["a"] && !model.hasMore)
  }

  @Test func initialFailureCanRetryAndEmptySuccessEndsLoading() async throws {
    let pages = AlbumPages()
    let model = MacAlbumMediaViewModel(service: pages)
    let first = try #require(model.loadMore())
    await pages.waitForRequests(1)
    pages.fail(0)
    await first.value
    #expect(model.error != nil && !model.isLoading && !model.hasLoaded && model.hasMore)
    #expect(model.error == "加载超时，请重试")
    model.start()
    #expect(pages.cursors == [""])
    let retry = try #require(model.loadMore())
    await pages.waitForRequests(2)
    pages.finish(1, ids: [])
    await retry.value
    #expect(pages.cursors == ["", ""])
    #expect(model.media.isEmpty && model.hasLoaded && !model.hasMore && model.error == nil)
  }

  @Test func nextPageFailurePreservesPhotosAndRetriesSameCursor() async throws {
    let pages = AlbumPages()
    let model = MacAlbumMediaViewModel(service: pages)
    let first = try #require(model.loadMore())
    await pages.waitForRequests(1)
    pages.finish(0, ids: ["a", "b"], next: "page-2", more: true)
    await first.value
    let next = try #require(model.loadMore())
    await pages.waitForRequests(2)
    pages.fail(1)
    await next.value
    #expect(model.media.map(\.id) == ["a", "b"] && model.error != nil && model.hasMore)
    model.reached("b")
    #expect(pages.cursors.count == 2)
    let retry = try #require(model.loadMore())
    await pages.waitForRequests(3)
    pages.finish(2, ids: ["b", "c", "c", "d"])
    await retry.value
    #expect(pages.cursors == ["", "page-2", "page-2"])
    #expect(model.media.map(\.id) == ["a", "b", "c", "d"])
    #expect(model.sections.flatMap(\.items).map(\.index) == [0, 1, 2, 3])
    #expect(!model.hasMore && model.error == nil && model.name == "测试相册")
    #expect(model.loadMore() == nil)
  }

  @Test func cancelDiscardsLatePageWithoutReplacingNewLoad() async throws {
    let pages = AlbumPages()
    let model = MacAlbumMediaViewModel(service: pages)
    let old = try #require(model.loadMore())
    await pages.waitForRequests(1)
    model.cancel()
    #expect(!model.isLoading)
    let current = try #require(model.loadMore())
    await pages.waitForRequests(2)
    pages.finish(1, ids: ["new"])
    await current.value
    pages.finish(0, ids: ["old"], next: "stale", more: true)
    await old.value
    #expect(model.media.map(\.id) == ["new"] && !model.hasMore && model.error == nil)
  }

  @Test func simultaneousTriggersDoNotIssueDuplicateRequests() async throws {
    let pages = AlbumPages()
    let model = MacAlbumMediaViewModel(service: pages)
    let request = try #require(model.loadMore())
    #expect(model.loadMore() == nil)
    model.start()
    await pages.waitForRequests(1)
    pages.finish(0, ids: ["a"])
    await request.value
    #expect(pages.cursors == [""] && model.media.count == 1)
  }

  @Test func repeatingCursorStopsAutomaticLoopButAllowsRetry() async throws {
    let pages = AlbumPages()
    let model = MacAlbumMediaViewModel(service: pages)
    let first = try #require(model.loadMore())
    await pages.waitForRequests(1)
    pages.finish(0, ids: ["a"], next: "page-2", more: true)
    await first.value
    let next = try #require(model.loadMore())
    await pages.waitForRequests(2)
    pages.finish(1, ids: ["b"], next: "page-2", more: true)
    await next.value
    #expect(model.error != nil && model.media.map(\.id) == ["a"])
    model.reached("a")
    #expect(pages.cursors.count == 2)
    let retry = try #require(model.loadMore())
    await pages.waitForRequests(3)
    pages.finish(2, ids: ["b"])
    await retry.value
    #expect(model.media.map(\.id) == ["a", "b"] && !model.hasMore && model.error == nil)
  }
}
