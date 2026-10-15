import Foundation
import Observation

@MainActor @Observable
final class MacStorageReferencesViewModel {
  private(set) var chats: [MacStorageReference] = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var error: String?
  @ObservationIgnored private let service: any MacStorageReferencesService
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?

  init(service: any MacStorageReferencesService) { self.service = service }
  deinit { task?.cancel() }

  func start() { if !hasLoaded, error == nil { reload() } }

  @discardableResult func reload() -> Task<Void, Never>? {
    guard !isLoading else { return nil }
    isLoading = true; error = nil
    let request = generation
    let work = Task { [weak self, service] in
      do {
        let references = try await service.references()
        guard let self, generation == request, !Task.isCancelled else { return }
        // 一个文件可以出现在同一会话的多条消息中；这里的入口按会话显示一次。
        var seen: Set<Int64> = []
        chats = references.filter { $0.id > 0 && seen.insert($0.id).inserted }
        hasLoaded = true; isLoading = false; task = nil
      } catch {
        guard let self, generation == request, !Task.isCancelled else { return }
        self.error = MacStorageFailure.describe(error); isLoading = false; task = nil
      }
    }
    task = work
    return work
  }

  func cancel() {
    generation = UUID(); task?.cancel(); task = nil; isLoading = false
  }
}
