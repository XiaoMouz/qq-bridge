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

  /// 历史窗口（见 ChatHistoryWindow）：包含 anchor 的那一段。
  func observeWindow(anchor: Int64, receive: @escaping @MainActor (ChatWindowSnapshot) -> Void) async throws {
    for try await snapshot in session.store.observeChatWindow(chatId: chatId, anchor: anchor) {
      try Task.checkCancellation()
      receive(snapshot)
    }
  }
}

/// 网络追平和本地订阅是两条独立链路；订阅中断时保留页面，显式重订阅才能继续显示新消息。
@MainActor @Observable
final class ChatMessageObservation {
  struct Request: Equatable {
    let limit: Int
    let retry: UUID
    /// 历史窗口的锚点；nil = 正常显示最新那段。
    var anchor: Int64? = nil
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
    await subscribe({ deliver in try await service.observe(limit: limit, receive: deliver) }, receive: receive)
  }

  func observeWindow(anchor: Int64, using service: SessionChatMessageObservationService,
                     receive: @escaping @MainActor (ChatWindowSnapshot) -> Void) async {
    await subscribe({ deliver in try await service.observeWindow(anchor: anchor, receive: deliver) }, receive: receive)
  }

  private func subscribe<Value>(_ start: (@escaping @MainActor (Value) -> Void) async throws -> Void,
                                receive: @escaping @MainActor (Value) -> Void) async {
    guard !Task.isCancelled else { return }
    let request = UUID()
    generation = request
    error = nil
    do {
      try await start { [weak self] value in
        guard let self, generation == request, !Task.isCancelled else { return }
        receive(value)
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
