import Foundation
import Testing
@testable import BetterChat

@MainActor private final class StorageReferencesReplies: MacStorageReferencesService {
  var count = 0
  var replies: [Int: CheckedContinuation<[MacStorageReference], any Error>] = [:]
  func references() async throws -> [MacStorageReference] {
    let index = count
    return try await withCheckedThrowingContinuation { replies[index] = $0; count += 1 }
  }
  func finish(_ index: Int, ids: [Int64]) {
    replies.removeValue(forKey: index)?.resume(returning: ids.map {
      MacStorageReference(id: $0, scene: .group, peerID: $0 + 100)
    })
  }
  func fail(_ index: Int) { replies.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct MacStorageReferencesTests {
  private func wait(_ condition: () -> Bool) async {
    let end = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < end { await Task.yield() }
    #expect(condition())
  }

  @Test func coalescesLoadsAndShowsOneRowPerValidChat() async {
    let service = StorageReferencesReplies(), model = MacStorageReferencesViewModel(service: StorageReferencesReplies())
    // 独立实例确保加载状态不跨文件共享。
    let firstModel = MacStorageReferencesViewModel(service: service)
    let work = firstModel.reload(); firstModel.start()
    #expect(firstModel.reload() == nil && firstModel.isLoading && !model.isLoading)
    await wait { service.count == 1 }
    service.finish(0, ids: [153, 153, 0, -1, 12]); await work?.value
    #expect(firstModel.chats.map(\.id) == [153, 12])
    #expect(firstModel.chats[0].scene == .group && firstModel.chats[0].peerID == 253)
    #expect(firstModel.hasLoaded && firstModel.error == nil && !firstModel.isLoading)
    firstModel.start(); #expect(!firstModel.isLoading)
  }

  @Test func firstFailureRequiresRetryAndEmptySuccessIsDistinct() async {
    let service = StorageReferencesReplies(); let model = MacStorageReferencesViewModel(service: service)
    let work = model.reload(); await wait { service.count == 1 }
    service.fail(0); await work?.value
    #expect(model.error == "加载超时，请重试" && !model.hasLoaded && model.chats.isEmpty)
    model.start(); #expect(!model.isLoading)
    let retry = model.reload(); await wait { service.count == 2 }
    #expect(model.error == nil && model.isLoading)
    service.finish(1, ids: []); await retry?.value
    #expect(model.hasLoaded && model.error == nil && !model.isLoading && model.chats.isEmpty)
  }

  @Test func failedRefreshRetainsUsableRowsUntilSuccessfulReplacement() async {
    let service = StorageReferencesReplies(); let model = MacStorageReferencesViewModel(service: service)
    let first = model.reload(); await wait { service.count == 1 }
    service.finish(0, ids: [153]); await first?.value
    let second = model.reload(); await wait { service.count == 2 }
    #expect(model.chats.map(\.id) == [153])
    service.fail(1); await second?.value
    #expect(model.hasLoaded && model.chats.map(\.id) == [153] && model.error != nil)
    let retry = model.reload(); await wait { service.count == 3 }
    service.finish(2, ids: [12]); await retry?.value
    #expect(model.chats.map(\.id) == [12] && model.error == nil)
  }

  @Test(arguments: [false, true]) func cancelledResponseCannotOverwriteReopenedPage(fails: Bool) async {
    let service = StorageReferencesReplies(); let model = MacStorageReferencesViewModel(service: service)
    let old = model.reload(); await wait { service.count == 1 }
    model.cancel(); #expect(!model.isLoading && !model.hasLoaded)
    model.start(); await wait { service.count == 2 }
    service.finish(1, ids: [153]); await wait { !model.isLoading }
    if fails { service.fail(0) } else { service.finish(0, ids: [12]) }
    await old?.value
    #expect(model.chats.map(\.id) == [153] && model.error == nil && model.hasLoaded)
  }
}
