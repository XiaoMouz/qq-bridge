import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto

/// 加载快照与选择一起提交，避免 QQ 刷新操作 ID 后批量动作仍指向旧文件。
@MainActor @Observable
final class MacGroupFilesViewModel {
  private(set) var folders: [Qqbridge_V1_GroupFolder] = []
  var files: [Qqbridge_V1_GroupFile] = []
  var selection: Set<String> = []
  private(set) var isLoading = false
  private(set) var hasLoaded = false
  private(set) var error: String?
  @ObservationIgnored private let service: any MacGroupFilesService
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(service: any MacGroupFilesService) { self.service = service }
  deinit { task?.cancel() }

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
        selection = GroupFileSelection.refreshed(selection, from: files.map(Self.selectionItem), to: result.files.map(Self.selectionItem))
        folders = result.folders
        files = result.files
        hasLoaded = true
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

  private static func selectionItem(_ file: Qqbridge_V1_GroupFile) -> GroupFileSelection.Item {
    .init(id: file.id, key: .init(name: file.name, size: file.size, modified: file.modifyTime, uploader: file.uploaderID, busid: file.busid))
  }
}
