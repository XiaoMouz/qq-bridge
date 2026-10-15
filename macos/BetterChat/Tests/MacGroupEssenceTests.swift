import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor
private final class EssenceWatch: MacEssenceMediaWatch {
  private var waiter: CheckedContinuation<Bool, Never>?
  private var buffered = false
  private(set) var cancelled = false
  func next() async -> Bool {
    if cancelled { return false }
    if buffered { buffered = false; return true }
    return await withCheckedContinuation { waiter = $0 }
  }
  func emit() {
    guard !cancelled else { return }
    if let waiter { self.waiter = nil; waiter.resume(returning: true) }
    else { buffered = true }
  }
  func cancel() {
    cancelled = true
    let pending = waiter
    waiter = nil
    pending?.resume(returning: false)
  }
}

@MainActor
private final class EssenceReplies: MacGroupEssenceService {
  private(set) var count = 0
  var watches: [(Set<Int64>, EssenceWatch)] = []
  var pending: [Int: CheckedContinuation<[Qqbridge_V1_GroupEssence], any Error>] = [:]
  func load() async throws -> [Qqbridge_V1_GroupEssence] {
    let index = count
    count += 1
    return try await withCheckedThrowingContinuation { pending[index] = $0 }
  }
  func watch(seqs: Set<Int64>) -> any MacEssenceMediaWatch {
    let watch = EssenceWatch()
    watches.append((seqs, watch))
    return watch
  }
  func requestThumbnail(seq: Int64, ord: UInt32) {}
  func finish(_ index: Int, _ items: [Qqbridge_V1_GroupEssence]) {
    pending.removeValue(forKey: index)?.resume(returning: items)
  }
  func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
}

@Suite(.serialized) @MainActor
struct MacGroupEssenceTests {
  private func settle(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    #expect(condition())
  }
  private func item(_ seq: Int64, state: Qqbridge_V1_MediaState = .pending, thumb: String = "") -> Qqbridge_V1_GroupEssence {
    var result = Qqbridge_V1_GroupEssence()
    result.seq = seq
    var image = Qqbridge_V1_ImageSegment()
    image.media.state = state
    image.media.thumbSha256 = thumb
    var segment = Qqbridge_V1_Segment()
    segment.kind = .image(image)
    result.message.segments = [segment]
    return result
  }

  @Test func firstFailureRetryArmsWatchAndMediaEventRefreshesList() async throws {
    let replies = EssenceReplies()
    let model = MacGroupEssenceViewModel(service: replies)
    defer { model.cancel() }
    let first = model.load()
    await settle { replies.count == 1 }
    replies.fail(0); await first.value
    #expect(model.error == "加载超时，请重试" && !model.hasLoaded)
    model.start()
    #expect(replies.count == 1)
    let retry = model.load()
    await settle { replies.count == 2 }
    replies.finish(1, [item(3)]); await retry.value
    let watch = try #require(replies.watches.first?.1)
    #expect(replies.watches.first?.0 == [3])
    watch.emit()
    await settle { replies.count == 3 }
    replies.finish(2, [item(3, state: .stored, thumb: "ready")])
    await settle { !model.isLoading }
    #expect(model.error == nil && model.items.first?.message.segments.first?.image.media.thumbSha256 == "ready")
    #expect(watch.cancelled && replies.watches.count == 1)
  }

  @Test func eventDuringRefreshRequiresOneFollowupAndRefreshFailureKeepsRows() async throws {
    let replies = EssenceReplies()
    let model = MacGroupEssenceViewModel(service: replies)
    defer { model.cancel() }
    let initial = model.load()
    await settle { replies.count == 1 }
    replies.finish(0, [item(5)]); await initial.value
    let watch = try #require(replies.watches.first?.1)
    let refresh = model.load()
    await settle { replies.count == 2 }
    watch.emit()
    for _ in 0..<30 { await Task.yield() }
    replies.finish(1, [item(5)]); await refresh.value
    await settle { replies.count == 3 }
    replies.fail(2)
    await settle { !model.isLoading }
    #expect(model.items.map(\.seq) == [5] && model.error != nil)
    #expect(replies.watches.allSatisfy { $0.1.cancelled })
    let retry = model.load()
    await settle { replies.count == 4 }
    replies.finish(3, []); await retry.value
    #expect(model.items.isEmpty && model.hasLoaded && model.error == nil)
  }

  @Test func returningAfterMissedMediaEventRevalidatesPendingRows() async {
    let replies = EssenceReplies()
    let model = MacGroupEssenceViewModel(service: replies)
    defer { model.cancel() }
    let first = model.load()
    await settle { replies.count == 1 }
    replies.finish(0, [item(9)]); await first.value
    model.cancel()
    #expect(replies.watches.allSatisfy { $0.1.cancelled })
    // 离开期间完成的事件不会重放；不能只订阅旧快照，必须读回最新缩略图状态。
    model.start()
    #expect(model.isLoading)
    if model.isLoading {
      await settle { replies.count == 2 }
      replies.finish(1, [item(9, state: .stored, thumb: "finished-while-away")])
      await settle { !model.isLoading }
      #expect(model.items.first?.message.segments.first?.image.media.thumbSha256 == "finished-while-away")
    }
  }

  @Test func cancellationIsolatesLateRepliesAndTerminalMediaDoesNotSubscribe() async {
    let replies = EssenceReplies()
    let model = MacGroupEssenceViewModel(service: replies)
    defer { model.cancel() }
    let old = model.load()
    await settle { replies.count == 1 }
    model.cancel()
    let current = model.load()
    await settle { replies.count == 2 }
    replies.finish(1, [item(20, state: .expired), item(21, state: .failed), item(22, state: .stored)])
    await current.value
    replies.fail(0); await old.value
    #expect(model.items.map(\.seq) == [20,21,22] && model.error == nil && replies.watches.isEmpty)
  }

  @Test func cancelledMediaReadyWatchDropsBufferedEventsAndReleasesWaiter() async {
    let hub = MediaReady()
    let watch = hub.watch(chatId: 153, seq: 9)
    var event = Qqbridge_V1_MediaReadyUpdate()
    event.chatID = 153; event.seq = 9; event.node = -1
    hub.publish(event)
    watch.cancel()
    #expect(await watch.next(timeout: .seconds(1)) == nil)
    let waiting = hub.watch(chatId: 153, seq: 9)
    let task = Task { await waiting.next(timeout: .seconds(30)) }
    await Task.yield()
    waiting.cancel()
    #expect(await task.value == nil)
    hub.publish(event)
    #expect(await waiting.next(timeout: .seconds(1)) == nil)
  }

  @Test func adapterTaskCancellationReleasesSubscriptionImmediately() async {
    let hub = MediaReady()
    let source = hub.watch(chatId: 153, seq: 10)
    let adapter = MacEssenceWatch(source: source)
    let task = Task { await adapter.next() }
    await Task.yield()
    task.cancel()
    #expect(await task.value == false)
    #expect(await source.next(timeout: .seconds(1)) == nil)
  }
}
