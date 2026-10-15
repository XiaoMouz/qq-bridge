import Foundation
import Observation
import QQBridgeKit

@MainActor
protocol ChatMessageObservationService {
  func observe(limit: Int, receive: @escaping @MainActor ([ChatItem]) -> Void) async throws
}

@MainActor
struct SessionChatMessageObservationService: ChatMessageObservationService {
  let session: Session
  let chatId: Int64

  func observe(limit: Int, receive: @escaping @MainActor ([ChatItem]) -> Void) async throws {
    for try await items in session.store.observeChat(chatId: chatId, limit: limit) {
      try Task.checkCancellation()
      receive(items)
    }
  }
}

/// 网络追平和本地订阅是两条独立链路；订阅中断时保留页面，显式重订阅才能继续显示新消息。
@MainActor @Observable
final class ChatMessageObservation {
  struct Request: Equatable {
    let limit: Int
    let retry: UUID
  }

  private(set) var error: String?
  private(set) var retry = UUID()
  @ObservationIgnored private var generation = UUID()

  func restart() {
    generation = UUID()
    retry = UUID()
    error = nil
  }

  func cancel() { generation = UUID() }

  func observe(limit: Int, using service: any ChatMessageObservationService,
               receive: @escaping @MainActor ([ChatItem]) -> Void) async {
    guard !Task.isCancelled else { return }
    let request = UUID()
    generation = request
    error = nil
    do {
      try await service.observe(limit: limit) { [weak self] items in
        guard let self, generation == request, !Task.isCancelled else { return }
        receive(items)
      }
      // 数据库观察应持续到页面取消；意外正常结束也不能悄悄让页面失去更新。
      guard generation == request, !Task.isCancelled else { return }
      error = "消息列表已停止更新，请重试"
    } catch {
      guard generation == request, !Task.isCancelled else { return }
      self.error = LoadState.describe(error)
    }
  }
}
