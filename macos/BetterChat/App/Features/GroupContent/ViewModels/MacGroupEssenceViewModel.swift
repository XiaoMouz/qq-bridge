import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

@MainActor @Observable
final class MacGroupEssenceViewModel {
  private(set) var items: [Qqbridge_V1_GroupEssence] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var error: String?
  @ObservationIgnored private let service: any MacGroupEssenceService
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var watchTask: Task<Void, Never>?
  @ObservationIgnored private var watch: (any MacEssenceMediaWatch)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var watchGeneration = UUID()
  @ObservationIgnored private var mediaChangedDuringLoad = false

  init(service: any MacGroupEssenceService) { self.service = service }
  deinit {
    task?.cancel()
    watchTask?.cancel()
  }

  func start() {
    guard error == nil else { return }
    if !hasLoaded { load() }
    // Subscribe 临时事件不会重放；离开期间媒体可能已完成，重进时补读一次状态再订阅。
    else if watch == nil, !pendingSequences(in: items).isEmpty { load() }
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    if let task { return task }
    isLoading = true
    error = nil
    let request = generation
    let next = Task { [weak self, service] in
      do {
        let result = try await service.load()
        guard let self, generation == request, !Task.isCancelled else { return }
        // 先登记再发布列表，缩略图视图开始请求之前就能接收快速完成的媒体通知。
        observeMedia(in: result)
        items = result
        hasLoaded = true
        isLoading = false
        task = nil
        if mediaChangedDuringLoad {
          mediaChangedDuringLoad = false
          load()
        }
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        stopWatching()
        mediaChangedDuringLoad = false
        self.error = (error as? URLError)?.code == .timedOut || (error as? APIError)?.code == .deadlineExceeded
          ? "加载超时，请重试" : LoadState.describe(error)
        isLoading = false
        task = nil
      }
    }
    task = next
    return next
  }

  func requestThumbnail(seq: Int64, ord: UInt32) { service.requestThumbnail(seq: seq, ord: ord) }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    stopWatching()
    mediaChangedDuringLoad = false
    isLoading = false
  }

  private func observeMedia(in items: [Qqbridge_V1_GroupEssence]) {
    stopWatching()
    let seqs = pendingSequences(in: items)
    guard !seqs.isEmpty else { return }
    let watch = service.watch(seqs: seqs)
    self.watch = watch
    let request = watchGeneration
    watchTask = Task { [weak self, watch] in
      guard await watch.next(), !Task.isCancelled, let self, watchGeneration == request else { return }
      // 手动刷新与媒体完成可以交错：保留一次补拉，避免较旧快照覆盖已经到达的通知。
      if isLoading { mediaChangedDuringLoad = true }
      else { load() }
    }
  }

  private func pendingSequences(in items: [Qqbridge_V1_GroupEssence]) -> Set<Int64> {
    Set(items.filter { item in
      item.hasMessage && item.message.segments.contains { segment in
        guard case .image(let image) = segment.kind else { return false }
        return image.media.thumbSha256.isEmpty && image.media.state != .stored
          && image.media.state != .expired && image.media.state != .failed
      }
    }.map(\.seq))
  }

  private func stopWatching() {
    watchGeneration = UUID()
    watch?.cancel()
    watch = nil
    watchTask?.cancel()
    watchTask = nil
  }
}
