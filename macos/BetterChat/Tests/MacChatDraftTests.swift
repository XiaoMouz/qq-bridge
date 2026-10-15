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
  func rememberLastChat(_ id: Int64) { lastChat = id }
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
