import Foundation
import Observation
import QQBridgeKit

/// 会话右键里的写操作；失败提示要说清是哪个会话的哪个动作。
enum MacDialogAction: Equatable, Sendable {
  case pin, unpin, markRead, mute, unmute, archive, unarchive

  var title: String {
    switch self {
    case .pin: "置顶"
    case .unpin: "取消置顶"
    case .markRead: "标为已读"
    case .mute: "免打扰"
    case .unmute: "接收并提醒"
    case .archive: "收进群助手"
    case .unarchive: "移出群助手"
    }
  }
}

/// 一条待确认的失败。观察失败需要显式重试才恢复；写操作失败只提示，不自动重放。
/// 每条有独立身份，确认时只移除已呈现的那条，较新的失败不会被旧弹窗的关闭清掉。
struct MacDialogsFailure: Identifiable, Equatable {
  enum Kind: Equatable {
    case observation
    case operation(chatID: Int64, action: MacDialogAction)
  }
  let id = UUID()
  let kind: Kind
  let title: String
  let message: String
}

/// 列表状态和业务操作不依赖 UIKit；控制器只负责差量渲染与用户意图转发。
@MainActor
@Observable
final class MacDialogsViewModel {
  private(set) var items: [DialogItem] = []
  private(set) var byID: [Int64: DialogItem] = [:]
  private(set) var selectedID: Int64?
  private(set) var showsArchived = false
  /// 按发生顺序排队，控制器一次呈现一条。
  private(set) var failures: [MacDialogsFailure] = []
  /// 本地库观察已出错停止；已显示的列表保留，等用户重试。
  private(set) var observationFailed = false
  @ObservationIgnored private let service: any MacConversationService
  @ObservationIgnored private let manualSync: MacManualSync
  @ObservationIgnored private var updated: (@MainActor ([DialogItem]) -> Void)?
  @ObservationIgnored private var observation: Task<Void, Never>?
  /// 所有未结束的写任务（析构时全部取消）；writeTails 记每个会话最后排入的那个，后来的写入等它结束再发。
  @ObservationIgnored private var writeTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var writeTails: [Int64: UUID] = [:]
  @ObservationIgnored private var lastScrolledUnread: Int64?

  init(service: any MacConversationService, manualSync: MacManualSync) {
    self.service = service
    self.manualSync = manualSync
  }
  deinit {
    observation?.cancel()
    for task in writeTasks.values { task.cancel() }
  }

  var archived: [DialogItem] { items.filter(\.isArchived) }
  var visible: [DialogItem] { items.filter { $0.isArchived == showsArchived } }

  /// updated 会被保存，重试观察后继续用它更新角标。
  func start(updated: @escaping @MainActor ([DialogItem]) -> Void) {
    self.updated = updated
    observe()
  }

  /// 只由用户显式触发（弹窗「重试」、手动刷新），观察失败后不自动重启。
  func retryObservation() {
    guard observationFailed else { return }
    observe()
  }

  private func observe() {
    guard observation == nil, let updated else { return }
    observationFailed = false
    failures.removeAll { $0.kind == .observation }
    observation = Task { [weak self, service] in
      do {
        try await service.observe { [weak self] items in
          guard let self, !Task.isCancelled else { return }
          self.items = items
          self.byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
          updated(items)
        }
      } catch {
        guard !Task.isCancelled, let self else { return }
        // 保留 items：列表和角标停在最后一次结果，比清空更不容易误导。
        self.observation = nil
        self.observationFailed = true
        self.failures.append(MacDialogsFailure(
          kind: .observation, title: "会话列表停止更新",
          message: "\(error.localizedDescription)\n已显示的会话保持不变，可以重试。"))
        return
      }
      self?.observation = nil
    }
  }

  func select(_ id: Int64) { selectedID = id }
  func setArchived(_ archived: Bool) { showsArchived = archived }
  /// 只移除这一条；身份不在队列里（已被重试清掉等）时不动其他失败。
  func acknowledge(_ id: MacDialogsFailure.ID) { failures.removeAll { $0.id == id } }

  /// 手动刷新也是用户的显式重试，顺带恢复已停止的观察。
  func refresh(completed: @escaping @MainActor () -> Void) {
    retryObservation()
    manualSync.start(operation: { [service] in try await service.refresh() }, completed: completed)
  }

  func nextUnread() -> DialogItem? {
    let unread = items.filter { !$0.isArchived && $0.badgeCount > 0 }
    guard !unread.isEmpty else { return nil }
    let current = unread.firstIndex { $0.id == selectedID }
    return unread[current.map { ($0 + 1) % unread.count } ?? 0]
  }

  func nextUnreadToScroll(orderedIDs: [Int64]) -> Int64? {
    let unread = orderedIDs.filter { id in
      guard let item = byID[id] else { return false }
      return !item.isArchived && item.badgeCount > 0
    }
    guard !unread.isEmpty else { lastScrolledUnread = nil; return nil }
    let current = lastScrolledUnread.flatMap { unread.firstIndex(of: $0) }
    let next = unread[current.map { ($0 + 1) % unread.count } ?? 0]
    lastScrolledUnread = next
    return next
  }

  /// 测试用：仍有写任务未结束（含排队等待的）。
  var hasPendingWrites: Bool { !writeTasks.isEmpty }

  func togglePinned(_ item: DialogItem) {
    let pinned = !item.dialog.pinned
    enqueue(item, pinned ? .pin : .unpin) { [service] in try await service.setPinned(chatID: item.id, pinned: pinned) }
  }
  func markRead(_ item: DialogItem) {
    enqueue(item, .markRead) { [service] in try await service.markRead(chatID: item.id, sequence: item.dialog.topSeq) }
  }
  func toggleMuted(_ item: DialogItem) {
    let policy = item.isMuted ? (item.isGroup ? "all" : "default") : "muted"
    setPolicy(item, item.isMuted ? .unmute : .mute, policy)
  }
  func toggleArchived(_ item: DialogItem) {
    setPolicy(item, item.isArchived ? .unarchive : .archive, item.isArchived ? "muted" : "archived")
  }
  private func setPolicy(_ item: DialogItem, _ action: MacDialogAction, _ policy: String) {
    enqueue(item, action) { [service] in try await service.setPolicy(chatID: item.id, policy: policy) }
  }

  /// 同一会话按点击顺序提交：两次 setPolicy 并发发出时到达服务端的顺序没有保证，
  /// 先「免打扰」再「收进群助手」可能停在 muted。不同会话互不等待。
  private func enqueue(_ item: DialogItem, _ action: MacDialogAction,
                       _ operation: @escaping @MainActor () async throws -> Void) {
    let chatID = item.id, name = item.title
    let previous = writeTails[chatID].flatMap { writeTasks[$0] }
    let token = UUID()
    writeTasks[token] = Task { [weak self] in
      // Task.value 不响应取消；等前一个结束后再看自己是否已取消，取消了就不再提交。
      await previous?.value
      if !Task.isCancelled {
        do { try await operation() }
        catch is CancellationError {}
        catch {
          if !Task.isCancelled {
            self?.failures.append(MacDialogsFailure(
              kind: .operation(chatID: chatID, action: action),
              title: "\(action.title)「\(name)」失败", message: error.localizedDescription))
          }
        }
      }
      self?.finishWrite(token, chatID: chatID)
    }
    writeTails[chatID] = token
  }
  private func finishWrite(_ token: UUID, chatID: Int64) {
    writeTasks[token] = nil
    if writeTails[chatID] == token { writeTails[chatID] = nil }
  }
}
