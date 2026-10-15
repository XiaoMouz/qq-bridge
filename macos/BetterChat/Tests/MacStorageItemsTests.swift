import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class StoragePages: MacStorageItemsService {
  var offsets: [UInt32] = []
  var replies: [Int: CheckedContinuation<MacStorageItemsPage, any Error>] = [:]
  func page(offset: UInt32) async throws -> MacStorageItemsPage {
    let index = offsets.count
    return try await withCheckedThrowingContinuation {
      replies[index] = $0; offsets.append(offset)
    }
  }
  func finish(_ index: Int, items: [StorageItemModel] = [], more: Bool = false) {
    replies.removeValue(forKey: index)?.resume(returning: MacStorageItemsPage(items: items, more: more))
  }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.notConnectedToInternet)) }
}

@Suite(.serialized) @MainActor
struct MacStorageItemsTests {
  private func wait(_ condition: () -> Bool) async {
    let end = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < end { await Task.yield() }
    #expect(condition())
  }
  private func item(_ sha: String, size: UInt64 = 10) -> StorageItemModel {
    var item = Qqbridge_V1_StorageItem(); item.sha256 = sha; item.size = size; item.category = "file"
    return StorageItemModel(server: item)
  }

  @Test func duplicateAppearancesDoNotRequestTheSamePage() async {
    let service = StoragePages(); let model = MacStorageItemsViewModel(service: service)
    let first = model.loadMore(); model.start(); model.loadMore()
    await wait { service.offsets.count == 1 }
    service.finish(0, items: [item("a")], more: true); await first?.value
    model.reached("not-last"); #expect(!model.isLoading)
    let next = model.loadMore(); model.reached("a")
    await wait { service.offsets.count == 2 }
    #expect(service.offsets == [0, 1])
    service.finish(1, items: [item("b")]); await next?.value
    #expect(model.items.map(\.id) == ["a", "b"] && !model.hasMore)
    #expect(model.loadMore() == nil)
  }

  @Test func paginationFailureKeepsGridAndOffsetUntilExplicitRetry() async {
    let service = StoragePages(); let model = MacStorageItemsViewModel(service: service)
    let first = model.loadMore(); await wait { service.offsets.count == 1 }
    service.finish(0, items: [item("a")], more: true); await first?.value
    let second = model.loadMore(); await wait { service.offsets.count == 2 }
    service.fail(1); await second?.value
    #expect(model.items.count == 1 && model.error != nil && model.hasMore)
    model.reached("a"); model.start(); #expect(!model.isLoading)
    let retry = model.loadMore(); await wait { service.offsets.count == 3 }
    #expect(service.offsets == [0, 1, 1])
    service.finish(2, items: [item("b")]); await retry?.value
    #expect(model.error == nil && model.items.count == 2)
  }

  @Test func duplicateItemsUpdateAndOffsetUsesRawPageCount() async {
    let service = StoragePages(); let model = MacStorageItemsViewModel(service: service)
    let first = model.loadMore(); await wait { service.offsets.count == 1 }
    service.finish(0, items: [item("a"), item("a", size: 20)], more: true); await first?.value
    #expect(model.items.count == 1 && model.items[0].size == 20)
    let next = model.loadMore(); await wait { service.offsets.count == 2 }
    #expect(service.offsets[1] == 2)
    service.finish(1, items: [item("a", size: 30), item("b")]); await next?.value
    #expect(model.items.map(\.id) == ["a", "b"] && model.items[0].size == 30)
  }

  @Test func emptyPageWithMoreIsRetryableNotInfiniteLoading() async {
    let service = StoragePages(); let model = MacStorageItemsViewModel(service: service)
    let first = model.loadMore(); await wait { service.offsets.count == 1 }
    service.finish(0, more: true); await first?.value
    #expect(model.error != nil && !model.isLoading && !model.hasLoaded)
    model.start(); #expect(!model.isLoading)
    let retry = model.loadMore(); await wait { service.offsets.count == 2 }
    #expect(service.offsets == [0, 0])
    service.finish(1); await retry?.value
    #expect(model.hasLoaded && !model.hasMore && model.error == nil && model.items.isEmpty)
  }

  @Test(arguments: [false, true]) func leavingAndReturningRejectsOldReply(fails: Bool) async {
    let service = StoragePages(); let model = MacStorageItemsViewModel(service: service)
    let old = model.loadMore(); await wait { service.offsets.count == 1 }
    model.cancel(); model.start(); await wait { service.offsets.count == 2 }
    service.finish(1, items: [item("new")]); await wait { !model.isLoading }
    if fails { service.fail(0) } else { service.finish(0, items: [item("old")], more: true) }
    await old?.value
    #expect(model.items.map(\.id) == ["new"] && model.error == nil && !model.hasMore)
  }

  @Test func cancelledLaterPageCanResumeWithoutDiscardingFirstPage() async {
    let service = StoragePages(); let model = MacStorageItemsViewModel(service: service)
    let first = model.loadMore(); await wait { service.offsets.count == 1 }
    service.finish(0, items: [item("a")], more: true); await first?.value
    let old = model.loadMore(); await wait { service.offsets.count == 2 }
    model.cancel(); model.start(); #expect(!model.isLoading && model.items.count == 1)
    let retry = model.loadMore(); await wait { service.offsets.count == 3 }
    service.finish(1, items: [item("old")]); await old?.value
    #expect(model.isLoading && model.items.map(\.id) == ["a"])
    service.finish(2, items: [item("b")]); await retry?.value
    #expect(model.items.map(\.id) == ["a", "b"] && service.offsets == [0, 1, 1])
  }
}

@MainActor private final class StorageOpenReplies: MacStorageFileService {
  var count = 0
  var replies: [Int: CheckedContinuation<MacStorageOpenedFile, any Error>] = [:]
  func file(for item: StorageItemModel) async throws -> MacStorageOpenedFile {
    let index = count; count += 1
    return try await withCheckedThrowingContinuation { replies[index] = $0 }
  }
  func finish(_ index: Int, url: URL, temporary: Bool) {
    replies.removeValue(forKey: index)?.resume(returning: MacStorageOpenedFile(url: url, temporary: temporary))
  }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.notConnectedToInternet)) }
}

@Suite(.serialized) @MainActor
struct MacStorageFileTests {
  private func item() -> StorageItemModel { StorageItemModel(server: Qqbridge_V1_StorageItem()) }
  private func wait(_ condition: () -> Bool) async {
    let end = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < end { await Task.yield() }
    #expect(condition())
  }
  private func file() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("StorageOpenTest-\(UUID().uuidString).txt")
    try Data("temporary test".utf8).write(to: url)
    return url
  }

  @Test func replacementDiscardsOldPreviewAndOnlyDeletesTemporaryFiles() async throws {
    let service = StorageOpenReplies(); let model = MacStorageFileViewModel(service: service)
    let oldURL = try file(), savedURL = try file()
    defer { try? FileManager.default.removeItem(at: oldURL); try? FileManager.default.removeItem(at: savedURL) }
    let old = model.open(item()); await wait { service.count == 1 }
    let next = model.open(item()); await wait { service.count == 2 }
    service.finish(1, url: savedURL, temporary: false); await next.value
    service.finish(0, url: oldURL, temporary: true); await old.value
    #expect(model.url == savedURL && !FileManager.default.fileExists(atPath: oldURL.path))
    model.cancel()
    #expect(model.url == nil && FileManager.default.fileExists(atPath: savedURL.path))
  }

  @Test func cancellingOpenIgnoresFailureAndLateSavedFileRemains() async throws {
    let service = StorageOpenReplies(); let model = MacStorageFileViewModel(service: service)
    let failed = model.open(item()); await wait { service.count == 1 }
    model.cancel(); service.fail(0); await failed.value
    #expect(model.error == nil && model.url == nil && model.opening == nil)
    let url = try file(); defer { try? FileManager.default.removeItem(at: url) }
    let task = model.open(item()); await wait { service.count == 2 }
    model.cancel(); service.finish(1, url: url, temporary: false); await task.value
    #expect(model.url == nil && FileManager.default.fileExists(atPath: url.path))
  }

  @Test func openingFailureRetriesAndDismissRemovesPreview() async throws {
    let service = StorageOpenReplies(); let model = MacStorageFileViewModel(service: service)
    let first = model.open(item()); await wait { service.count == 1 }
    service.fail(0); await first.value
    #expect(model.error != nil && model.opening == nil && model.url == nil)
    let url = try file(); defer { try? FileManager.default.removeItem(at: url) }
    let retry = model.open(item()); await wait { service.count == 2 }
    #expect(model.error == nil)
    service.finish(1, url: url, temporary: true); await retry.value
    #expect(model.url == url)
    model.cancel()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}
