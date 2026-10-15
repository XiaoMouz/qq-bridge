import Foundation
import Observation
import QQBridgeProto

/// 会话 ID 在页面生命周期内固定；取消与代次共同隔离修改关键词、离开页面后的迟到结果。
@MainActor
@Observable
final class MacChatHistoryViewModel {
  let chatID: Int64
  private(set) var query = ""
  private(set) var results: [Qqbridge_V1_Message] = []
  private(set) var searched: String?
  private(set) var isSearching = false
  private(set) var error: String?
  private(set) var isLoadingMore = false
  private(set) var moreError: String?
  private(set) var next: Qqbridge_V1_SearchCursor?
  @ObservationIgnored private let service: any MacChatHistoryService
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(chatID: Int64, service: any MacChatHistoryService) {
    self.chatID = chatID
    self.service = service
  }
  deinit { task?.cancel() }

  var canSearch: Bool { chatID > 0 && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  func updateQuery(_ query: String) {
    guard self.query != query else { return }
    cancel()
    self.query = query
    results = []
    searched = nil
    error = nil
    moreError = nil
    next = nil
  }

  func search() {
    guard canSearch else { return }
    cancel()
    results = []
    next = nil
    moreError = nil
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = generation
    isSearching = true
    error = nil
    task = Task { [weak self, service, chatID] in
      do {
        let page = try await service.search(chatID: chatID, query: term, before: nil)
        guard let self, !Task.isCancelled, generation == id else { return }
        // 即使服务端异常返回其他会话，也不允许详情页展示或跳转到其他会话的结果。
        results = page.messages.filter { $0.chatID == chatID }
        next = page.hasNext ? page.next : nil
        searched = term
        isSearching = false
        task = nil
      } catch {
        guard let self, !Task.isCancelled, generation == id else { return }
        results = []
        self.error = LoadState.describe(error)
        isSearching = false
        task = nil
      }
    }
  }

  func loadMore() {
    guard !isSearching, !isLoadingMore, let before = next, let term = searched else { return }
    let id = generation
    isLoadingMore = true
    moreError = nil
    task = Task { [weak self, service, chatID] in
      do {
        let page = try await service.search(chatID: chatID, query: term, before: before)
        guard let self, !Task.isCancelled, generation == id else { return }
        var seen = Set(results.map(\.seq))
        results += page.messages.filter { $0.chatID == chatID && seen.insert($0.seq).inserted }
        if page.hasNext, page.next == before {
          moreError = "搜索未能继续，请重试"
        } else {
          next = page.hasNext ? page.next : nil
        }
        isLoadingMore = false
        task = nil
      } catch {
        guard let self, !Task.isCancelled, generation == id else { return }
        moreError = LoadState.describe(error)
        isLoadingMore = false
        task = nil
      }
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    isSearching = false
    isLoadingMore = false
  }
}
