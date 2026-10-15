import Foundation
import Observation
import QQBridgeProto

/// 每个消息名单独立持有缓存；快速切换表情不能把上一种回应的人写进当前列表。
@MainActor @Observable
final class MacReactionUsersViewModel {
  private(set) var selected: String
  private(set) var isLoading = false
  private(set) var error: String?
  private var cache: [String: [Qqbridge_V1_ReactionUser]] = [:]
  var users: [Qqbridge_V1_ReactionUser] { cache[selected] ?? [] }
  var hasLoaded: Bool { cache[selected] != nil }
  @ObservationIgnored private let service: any MacReactionUsersService
  @ObservationIgnored private var request: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(selected: String, service: any MacReactionUsersService) {
    self.selected = selected
    self.service = service
  }
  deinit { request?.cancel() }

  func start() {
    if !hasLoaded, error == nil { load() }
  }

  func select(_ emojiID: String) {
    guard emojiID != selected else { return }
    cancel()
    selected = emojiID
    error = nil
    start()
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    if let request { return request }
    isLoading = true
    error = nil
    let id = generation
    let emoji = selected
    let next = Task { [weak self, service] in
      do {
        let users = try await service.load(emojiID: emoji)
        guard !Task.isCancelled, let self, generation == id else { return }
        cache[emoji] = users
        finish()
      } catch {
        guard !Task.isCancelled, let self, generation == id else { return }
        self.error = LoadState.describe(error)
        finish()
      }
    }
    request = next
    return next
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    finish()
  }

  private func finish() {
    request = nil
    isLoading = false
  }
}
