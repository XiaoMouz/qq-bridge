import Foundation
@testable import QQBridgeKit
import QQBridgeProto
import Testing
@testable import BetterChat

/// 观察与写请求都挂在 continuation 上，由测试逐个放行；不联网、不碰账号。
@MainActor private final class DialogReplies: MacConversationService {
  enum Write: Equatable { case pinned(Int64, Bool), read(Int64, Int64), policy(Int64, String) }
  var receivers: [@MainActor ([DialogItem]) -> Void] = []
  var observations: [CheckedContinuation<Void, any Error>] = []
  var writes: [Write] = []
  var pending: [CheckedContinuation<Void, any Error>] = []

  func observe(_ receive: @escaping @MainActor ([DialogItem]) -> Void) async throws {
    receivers.append(receive)
    try await withCheckedThrowingContinuation { observations.append($0) }
  }
  func refresh() async throws {}
  func setPinned(chatID: Int64, pinned: Bool) async throws { try await write(.pinned(chatID, pinned)) }
  func markRead(chatID: Int64, sequence: Int64) async throws { try await write(.read(chatID, sequence)) }
  func setPolicy(chatID: Int64, policy: String) async throws { try await write(.policy(chatID, policy)) }
  private func write(_ request: Write) async throws {
    try await withCheckedThrowingContinuation {
      pending.append($0)
      writes.append(request)
    }
  }
}

@MainActor private final class Badges { var values: [[Int64]] = [] }

@MainActor private func until(_ condition: () -> Bool) async {
  let limit = ContinuousClock.now + .seconds(3)
  while !condition(), ContinuousClock.now < limit { await Task.yield() }
  #expect(condition())
}
@MainActor private func settle() async { for _ in 0..<50 { await Task.yield() } }

private func item(_ id: Int64, _ name: String, group: Bool = false) -> DialogItem {
  var dialog = Qqbridge_V1_Dialog()
  dialog.chatID = id
  dialog.peerID = id
  dialog.scene = group ? .group : .friend
  dialog.notifyPolicy = group ? "all" : "default"
  var peer = Qqbridge_V1_Peer()
  peer.name = name
  return DialogItem(dialog: dialog, peer: peer)
}

@Suite(.serialized) @MainActor
struct MacDialogsTests {
  @Test func laterFailureIsQueuedAndAcknowledgedByIdentity() async {
    let replies = DialogReplies()
    let model = MacDialogsViewModel(service: replies, manualSync: MacManualSync())
    model.togglePinned(item(1, "甲"))
    model.toggleMuted(item(2, "乙"))
    // 不同会话互不等待，两条请求同时在途。
    await until { replies.writes.count == 2 }
    #expect(replies.writes == [.pinned(1, true), .policy(2, "muted")])
    replies.pending[0].resume(throwing: URLError(.notConnectedToInternet))
    await until { model.failures.count == 1 }
    let shown = model.failures[0]
    replies.pending[1].resume(throwing: URLError(.timedOut))
    await until { model.failures.count == 2 }
    #expect(shown.kind == .operation(chatID: 1, action: .pin) && shown.title.contains("甲"))
    let later = model.failures[1]
    #expect(later.kind == .operation(chatID: 2, action: .mute) && later.title.contains("乙"))
    // 旧弹窗关闭只移除自己；重复确认同一身份不能清掉较新的那条。
    model.acknowledge(shown.id)
    model.acknowledge(shown.id)
    #expect(model.failures == [later])
    model.acknowledge(later.id)
    await until { !model.hasPendingWrites }
    #expect(model.failures.isEmpty && replies.writes.count == 2)
  }

  @Test func observationFailureKeepsListAndRetriesOnlyWhenAsked() async {
    let replies = DialogReplies()
    let model = MacDialogsViewModel(service: replies, manualSync: MacManualSync())
    let badges = Badges()
    model.start { badges.values.append($0.map(\.id)) }
    await until { replies.receivers.count == 1 }
    replies.receivers[0]([item(1, "甲"), item(2, "乙")])
    model.retryObservation()
    #expect(replies.receivers.count == 1)
    replies.observations[0].resume(throwing: URLError(.cannotOpenFile))
    await until { model.observationFailed }
    #expect(model.items.map(\.id) == [1, 2] && model.failures.map(\.kind) == [.observation])
    await settle()
    #expect(replies.receivers.count == 1)
    // 确认后不重试：列表仍保留，观察不自动重启。
    model.acknowledge(model.failures[0].id)
    await settle()
    #expect(replies.receivers.count == 1 && model.observationFailed && model.items.count == 2)
    model.retryObservation()
    await until { replies.receivers.count == 2 }
    #expect(!model.observationFailed && model.failures.isEmpty)
    replies.receivers[1]([item(2, "乙")])
    #expect(model.items.map(\.id) == [2] && badges.values == [[1, 2], [2]])
    replies.observations[1].resume()
  }

  @Test func sameChatWritesKeepOrderWithoutBlockingOtherChats() async {
    let replies = DialogReplies()
    let model = MacDialogsViewModel(service: replies, manualSync: MacManualSync())
    let group = item(1, "群", group: true)
    model.toggleMuted(group)
    model.toggleArchived(group)
    model.togglePinned(item(2, "乙"))
    await until { replies.writes.count == 2 }
    await settle()
    #expect(replies.writes == [.policy(1, "muted"), .pinned(2, true)])
    replies.pending[1].resume()
    await settle()
    #expect(replies.writes.count == 2)
    // 前一个失败后，后一个照常按顺序发出；失败的那个不重放。
    replies.pending[0].resume(throwing: URLError(.timedOut))
    await until { replies.writes.count == 3 }
    #expect(replies.writes[2] == .policy(1, "archived"))
    replies.pending[2].resume()
    await until { !model.hasPendingWrites }
    #expect(replies.writes.count == 3 && model.failures.map(\.kind) == [.operation(chatID: 1, action: .mute)])
  }

  @Test func releasingModelCancelsQueuedWriteWithoutCommitting() async {
    let replies = DialogReplies()
    weak var released: MacDialogsViewModel?
    do {
      let model = MacDialogsViewModel(service: replies, manualSync: MacManualSync())
      released = model
      let group = item(1, "群", group: true)
      model.toggleMuted(group)
      model.toggleArchived(group)
      await until { replies.writes.count == 1 }
    }
    // 写任务只弱引用模型，排队中的任务不能让它留着。
    #expect(released == nil)
    replies.pending[0].resume()
    await settle()
    #expect(replies.writes == [.policy(1, "muted")])
  }
}
