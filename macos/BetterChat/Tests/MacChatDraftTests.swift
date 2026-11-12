import Foundation
import QQBridgeProto
import Testing
import UIKit
@testable import BetterChat

@MainActor
private final class DraftPageFactory: MacChatPageBuilding {
  var pages: [(Int64, MacChatDraft)] = []
  func empty(_ state: MacEmptyState) -> UIViewController { UIViewController() }
  func chat(_ id: Int64, draft: MacChatDraft) -> UIViewController {
    pages.append((id, draft))
    return UIViewController()
  }
}

@MainActor
private final class DraftWorkspaceStore: MacWorkspaceStore {
  var lastChat: Int64?
  var position: (chat: Int64, seq: Int64)?
  func rememberLastChat(_ id: Int64) { lastChat = id }
  func lastPosition(in id: Int64) -> Int64? { position?.chat == id ? position?.seq : nil }
  func rememberPosition(_ seq: Int64?, in id: Int64) { position = seq.map { (id, $0) } }
  func chatExists(_ id: Int64) -> Bool { true }
  func chatTitle(_ id: Int64) -> String? { "测试会话 \(id)" }
}

@Suite(.serialized)
@MainActor
struct MacChatDraftTests {
  private func fixture() -> (MacChatCoordinator, DraftPageFactory) {
    let factory = DraftPageFactory()
    return (MacChatCoordinator(factory: factory, store: DraftWorkspaceStore()), factory)
  }

  /// 重启后恢复上次会话（2026-11-12）：只有启动恢复的那一页带上次的位置，平常点开仍从最新开始。
  @Test func restoredChatCarriesLastPositionOnlyOnRestore() throws {
    let factory = DraftPageFactory()
    let store = DraftWorkspaceStore()
    store.lastChat = 7
    store.position = (7, 4200)
    let coordinator = MacChatCoordinator(factory: factory, store: store)
    #expect(coordinator.restorableChat == 7)
    coordinator.open(7, restoringPosition: true)
    let restored = try #require(factory.pages.last?.1)
    #expect(restored.restoredPosition == 4200 && restored.position == 4200)

    // 页面上报新的位置，切走时写盘；切回同一会话是新页面，从最新开始。
    restored.position = 4300
    coordinator.open(8)
    #expect(store.position?.chat == 7 && store.position?.seq == 4300)
    #expect(factory.pages.last?.1.restoredPosition == nil)
    coordinator.open(7)
    #expect(restored.restoredPosition == nil && restored.position == nil)
  }

  @Test func persistingAtBottomClearsPosition() throws {
    let (coordinator, factory) = fixture()
    coordinator.open(3)
    let draft = try #require(factory.pages.last?.1)
    draft.position = 99
    coordinator.persistPosition()
    draft.position = nil
    coordinator.persistPosition()
    coordinator.open(4)
    coordinator.open(3, restoringPosition: true)
    #expect(factory.pages.last?.1.restoredPosition == nil)
  }

  @Test func switchingChatsPreservesCompleteDraftWithoutSharingIt() throws {
    let (coordinator, factory) = fixture()
    coordinator.open(1)
    let original = try #require(coordinator.draftComposer(for: 1))
    original.text = "未发送 "
    original.insertMention(userId: 91, name: "测试成员")
    var reply = Qqbridge_V1_Message()
    reply.chatID = 1
    reply.seq = 12
    original.replyTo = reply
    let attachment = Attachment(payload: .image(Data([1, 2, 3])), preview: nil)
    original.attachments = [attachment]
    coordinator.open(2)
    let other = try #require(coordinator.draftComposer(for: 2))
    #expect(other !== original)
    #expect(other.text.isEmpty && other.replyTo == nil && other.attachments.isEmpty)
    other.text = "另一个会话"
    coordinator.open(1)
    let restored = try #require(coordinator.draftComposer(for: 1))
    #expect(restored === original)
    #expect(restored.segments().contains { $0.mentionUserID == 91 })
    #expect(restored.replyTo?.seq == 12)
    #expect(restored.attachments.map(\.id) == [attachment.id])
    #expect(factory.pages.first?.1 === factory.pages.last?.1)
    #expect(coordinator.draftComposer(for: 2)?.text == "另一个会话")
  }

  @Test func lateQuickReplyCloseWritesBackToOriginAfterNavigation() throws {
    let (coordinator, _) = fixture()
    coordinator.open(1)
    let quick = try #require(coordinator.draftComposer(for: 1)).copyDraft()
    quick.text = "浮层编辑后的草稿"
    coordinator.open(2)
    let target = coordinator.controller
    coordinator.updateDraft(quick, for: 1)
    #expect(coordinator.selectedChat == 2 && coordinator.controller === target)
    #expect(coordinator.draftComposer(for: 2)?.text == "")
    coordinator.open(1)
    #expect(coordinator.draftComposer(for: 1) === quick)
  }

  @Test func quickReplyForUnopenedChatAndBothExpandOrdersRetainDraft() throws {
    let (coordinator, factory) = fixture()
    coordinator.open(2)
    let quick = Composer()
    quick.text = "尚未在主窗口打开"
    coordinator.updateDraft(quick, for: 1)
    #expect(coordinator.selectedChat == 2)
    coordinator.open(1, composer: quick)
    let page = coordinator.controller
    let request = try #require(factory.pages.last).1.request
    coordinator.updateDraft(quick, for: 1)
    #expect(!coordinator.open(1, composer: quick))
    #expect(coordinator.controller === page)
    #expect(factory.pages.count == 2)
    #expect(factory.pages.last?.1.request != request)
    #expect(coordinator.draftComposer(for: 1) === quick)
  }

  @Test func clearingDraftRemainsClearedAndWorkspaceReleaseDropsIt() {
    var coordinator: MacChatCoordinator? = MacChatCoordinator(factory: DraftPageFactory(), store: DraftWorkspaceStore())
    coordinator?.open(1)
    weak var original: Composer? = coordinator?.draftComposer(for: 1)
    original?.text = "待清空"
    original?.reset()
    coordinator?.open(2)
    coordinator?.open(1)
    #expect(coordinator?.draftComposer(for: 1)?.text == "")
    coordinator = nil
    #expect(original == nil)
  }

  @Test func pendingImportCompletesInOriginAfterQuickReplyRoute() async throws {
    let (coordinator, _) = fixture()
    coordinator.open(1)
    let quick = try #require(coordinator.draftComposer(for: 1)).copyDraft()
    var finish: CheckedContinuation<AttachmentImportResult<BetterChat.Attachment>, Never>?
    quick.attachmentQueue.enqueueImport {
      await withCheckedContinuation { finish = $0 }
    }
    for _ in 0..<1_000 {
      if finish != nil { break }
      await Task.yield()
    }
    let continuation = try #require(finish)
    coordinator.open(2)
    coordinator.updateDraft(quick, for: 1)
    let attachment = Attachment(payload: .image(Data([4, 5])), preview: nil)
    continuation.resume(returning: AttachmentImportResult(attachments: [attachment]))
    for _ in 0..<1_000 {
      if quick.attachmentQueue.pendingImports == 0 { break }
      await Task.yield()
    }
    coordinator.open(1)
    #expect(coordinator.draftComposer(for: 1)?.attachments.map(\.id) == [attachment.id])
    #expect(coordinator.draftComposer(for: 2)?.attachments.isEmpty == true)
    #expect(quick.attachmentQueue.pendingImports == 0)
  }
}
