import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

/// 分页失败保留照片与游标，只有成功回包才能前进；页面离开后的迟到结果不得生效。
@MainActor @Observable
final class MacAlbumMediaViewModel {
  struct Entry: Identifiable {
    let index: Int
    let media: Qqbridge_V1_GroupAlbumMedia
    var id: String { media.id }
  }
  struct Section: Identifiable {
    let id: String
    let day: String
    var items: [Entry]
  }

  private(set) var media: [Qqbridge_V1_GroupAlbumMedia] = []
  private(set) var name = ""
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var hasMore = true
  private(set) var error: String?
  @ObservationIgnored private let service: any MacAlbumMediaService
  @ObservationIgnored private var cursor = ""
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?

  init(service: any MacAlbumMediaService) { self.service = service }
  deinit { task?.cancel() }

  var sections: [Section] {
    var result: [Section] = []
    for (index, item) in media.enumerated() {
      let day = Format.date(item.time)
      let entry = Entry(index: index, media: item)
      if result.last?.day == day { result[result.count - 1].items.append(entry) }
      else { result.append(Section(id: item.id, day: day, items: [entry])) }
    }
    return result
  }

  func start() {
    guard !hasLoaded, error == nil else { return }
    loadMore()
  }

  func reached(_ id: String) {
    guard id == media.last?.id, error == nil else { return }
    loadMore()
  }

  @discardableResult
  func loadMore() -> Task<Void, Never>? {
    guard hasMore, !isLoading else { return nil }
    isLoading = true
    error = nil
    let request = generation
    let requestedCursor = cursor
    task = Task { [weak self, service] in
      do {
        let response = try await service.page(after: requestedCursor)
        guard let self, generation == request, !Task.isCancelled else { return }
        // 服务端重复游标不能触发末项 onAppear 无限翻页；用户可显式重试同一页。
        if response.hasMore_p, !response.nextCursor.isEmpty, response.nextCursor == requestedCursor {
          error = "相册分页未推进，请重试"
        } else {
          var known = Set(media.map(\.id))
          media += response.media.filter { known.insert($0.id).inserted }
          cursor = response.nextCursor
          hasMore = response.hasMore_p && !cursor.isEmpty
          if name.isEmpty { name = response.albumName }
          hasLoaded = true
        }
        isLoading = false
        task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        if (error as? URLError)?.code == .timedOut || (error as? APIError)?.code == .deadlineExceeded {
          self.error = "加载超时，请重试"
        } else {
          self.error = LoadState.describe(error)
        }
        isLoading = false
        task = nil
      }
    }
    return task
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isLoading = false
  }
}
