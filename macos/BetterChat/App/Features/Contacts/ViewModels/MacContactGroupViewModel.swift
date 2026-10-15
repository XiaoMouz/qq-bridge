import Foundation
import Observation
import QQBridgeProto

@MainActor @Observable
final class MacContactGroupViewModel {
  private(set) var dialog: Qqbridge_V1_Dialog?
  private(set) var error: String?
  private(set) var isLoading = false
  @ObservationIgnored private let service: any MacContactGroupService
  @ObservationIgnored private let waitForDeadline: @MainActor () async throws -> Void
  @ObservationIgnored private var request: Task<Void, Never>?
  @ObservationIgnored private var deadline: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  init(service: any MacContactGroupService,
       waitForDeadline: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }) {
    self.service = service
    self.waitForDeadline = waitForDeadline
  }

  deinit { request?.cancel(); deadline?.cancel() }

  func start() {
    guard dialog == nil, error == nil else { return }
    load()
  }

  @discardableResult
  func load() -> Task<Void, Never> {
    if let request { return request }
    error = nil
    isLoading = true
    let id = UUID()
    generation = id
    let next = Task { [weak self, service] in
      do {
        let dialog = try await service.load()
        guard let self, generation == id, !Task.isCancelled else { return }
        self.dialog = dialog
        finish()
      } catch {
        guard let self, generation == id, !Task.isCancelled else { return }
        self.error = LoadState.describe(error)
        finish()
      }
    }
    request = next
    // 建会话成功不代表 Subscribe 已把资料写入本地；整个等待必须能结束并重试。
    deadline = Task { [weak self, waitForDeadline] in
      do { try await waitForDeadline() } catch { return }
      guard let self, generation == id, !Task.isCancelled else { return }
      cancel()
      error = "群会话同步超时，请重试"
    }
    return next
  }

  func cancel() {
    generation = UUID()
    request?.cancel()
    finish()
  }

  private func finish() {
    request = nil
    deadline?.cancel()
    deadline = nil
    isLoading = false
  }
}
