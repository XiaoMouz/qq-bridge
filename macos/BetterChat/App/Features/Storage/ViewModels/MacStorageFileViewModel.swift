import Foundation
import Observation

/// 迟到的文件只清理自己的预览副本，不能重新弹出 Quick Look，也不能删除用户下载。
@MainActor @Observable
final class MacStorageFileViewModel {
  private(set) var url: URL?
  private(set) var opening: String?
  var error: String?
  @ObservationIgnored private var result: MacStorageOpenedFile?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private let service: any MacStorageFileService
  init(service: any MacStorageFileService) { self.service = service }
  isolated deinit { task?.cancel(); result?.removeIfTemporary() }

  @discardableResult
  func open(_ item: StorageItemModel) -> Task<Void, Never> {
    cancel(); error = nil; opening = item.id
    let request = generation
    let work = Task { [weak self, service] in
      do {
        let result = try await service.file(for: item)
        guard let self, !Task.isCancelled, generation == request else { result.removeIfTemporary(); return }
        self.result = result; url = result.url; opening = nil; task = nil
      } catch {
        guard let self, !Task.isCancelled, generation == request else { return }
        self.error = MacStorageFailure.describe(error); opening = nil; task = nil
      }
    }
    task = work
    return work
  }

  func cancel() {
    generation = UUID(); task?.cancel(); task = nil; opening = nil
    url = nil; result?.removeIfTemporary(); result = nil
  }
}
