import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

/// 查询切换独立换代；分页失败不推进游标，不把暂时断网解释为历史已经结束。
@MainActor @Observable
final class MacSharedMediaViewModel {
  private(set) var query: MacSharedMediaQuery?
  private(set) var items: [Qqbridge_V1_SharedMedia] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var hasMore = true
  private(set) var error: String?
  @ObservationIgnored private let service: any MacSharedMediaService
  @ObservationIgnored private var before: Int64 = 0
  @ObservationIgnored private var offset: Int32 = 0
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?

  init(service: any MacSharedMediaService) { self.service = service }
  deinit { task?.cancel() }

  func select(_ query: MacSharedMediaQuery) {
    if self.query != query {
      cancel()
      self.query = query
      items = []
      before = 0
      offset = 0
      hasLoaded = false
      hasMore = true
      error = nil
    }
    if !hasLoaded, error == nil { loadMore() }
  }

  func reached(_ item: Qqbridge_V1_SharedMedia) {
    guard error == nil, item.key == items.last?.key else { return }
    loadMore()
  }

  @discardableResult
  func loadMore() -> Task<Void, Never>? {
    guard let query, hasMore, !isLoading else { return nil }
    isLoading = true
    error = nil
    let request = generation, before = before, offset = offset
    let next = Task { [weak self, service] in
      do {
        let response = try await service.page(query: query, before: before, offset: offset)
        guard let self, generation == request, !Task.isCancelled else { return }
        // proto 约定 newest 的 seq 递减，其他排序 offset 递增；异常游标保留原页供重试。
        let advances = query.usesSequence
          ? response.nextBeforeSeq == 0 || (response.nextBeforeSeq > 0 && (before == 0 || response.nextBeforeSeq < before))
          : response.nextOffset == 0 || response.nextOffset > offset
        if !advances {
          error = "分页未推进，请重试"
        } else {
          var indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { (Self.identity($0.element), $0.offset) })
          for item in response.items {
            let id = Self.identity(item)
            if let index = indices[id] { items[index] = item }
            else { indices[id] = items.count; items.append(item) }
          }
          self.before = response.nextBeforeSeq
          self.offset = response.nextOffset
          hasMore = query.usesSequence ? response.nextBeforeSeq != 0 : response.nextOffset != 0
          hasLoaded = true
        }
        isLoading = false
        task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        self.error = (error as? URLError)?.code == .timedOut || (error as? APIError)?.code == .deadlineExceeded
          ? "加载超时，请重试" : LoadState.describe(error)
        isLoading = false
        task = nil
      }
    }
    task = next
    return next
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isLoading = false
  }

  private static func identity(_ item: Qqbridge_V1_SharedMedia) -> String {
    let ord: UInt32
    switch item.segment.kind {
    case .image(let image): ord = image.media.ord
    case .video(let video): ord = video.media.ord
    case .file(let file): ord = file.media.ord
    default: return item.key
    }
    return "\(item.seq):\(item.kind.rawValue):\(ord)"
  }
}
