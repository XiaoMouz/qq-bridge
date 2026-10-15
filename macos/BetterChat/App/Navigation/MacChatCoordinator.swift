import QQBridgeKit
import UIKit

@MainActor
protocol MacChatPageBuilding {
  func empty(_ state: MacEmptyState) -> UIViewController
  func chat(_ id: Int64, draft: MacChatDraft) -> UIViewController
}

/// 消息分区的右栏：当前聊天控制器、草稿与上次会话。同一会话重复打开只发“回到聊天”请求，
/// 不重建页面，已加载的历史和输入内容都保留。
@MainActor
final class MacChatCoordinator {
  private let factory: any MacChatPageBuilding
  private let store: any MacWorkspaceStore
  private(set) var selectedChat: Int64?
  private(set) var controller: UIViewController
  private(set) var title = "消息"
  private var drafts: [Int64: MacChatDraft] = [:]

  init(factory: any MacChatPageBuilding, store: any MacWorkspaceStore) {
    self.factory = factory
    self.store = store
    controller = factory.empty(.chat)
  }

  /// 返回 true 表示换了新页面，需要右栏重新显示。
  @discardableResult
  func open(_ id: Int64, title: String? = nil, composer: Composer? = nil) -> Bool {
    let draft = draft(for: id)
    guard selectedChat != id else {
      if let composer { draft.composer = composer }
      draft.request = UUID()
      return false
    }
    selectedChat = id
    if let composer { draft.composer = composer }
    controller = factory.chat(id, draft: draft)
    self.title = title ?? store.chatTitle(id) ?? "消息"
    store.rememberLastChat(id)
    return true
  }

  /// 启动后恢复上次会话；会话已被删除或已有待打开的会话时跳过。
  var restorableChat: Int64? {
    guard selectedChat == nil, let id = store.lastChat, store.chatExists(id) else { return nil }
    return id
  }

  func draftComposer(for id: Int64) -> Composer? {
    drafts[id]?.composer
  }
  func updateDraft(_ composer: Composer, for id: Int64) {
    // 资料卡跳转会先切换主会话，快速回复的关闭回调可能随后到达；始终交回原会话。
    draft(for: id).composer = composer
  }

  private func draft(for id: Int64) -> MacChatDraft {
    if let draft = drafts[id] { return draft }
    let draft = MacChatDraft()
    drafts[id] = draft
    return draft
  }
}
