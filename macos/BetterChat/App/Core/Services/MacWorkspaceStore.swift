import Foundation
import QQBridgeKit

/// 工作区需要的少量本地读取与偏好：上次打开的会话、会话标题。协调器不直接碰数据库或 UserDefaults。
@MainActor
protocol MacWorkspaceStore {
  var lastChat: Int64? { get }
  func rememberLastChat(_ id: Int64)
  func chatExists(_ id: Int64) -> Bool
  func chatTitle(_ id: Int64) -> String?
}

@MainActor
struct MacSessionWorkspaceStore: MacWorkspaceStore {
  private static let lastChatKey = "mac.lastChat"
  let session: Session
  let defaults: UserDefaults

  init(session: Session, defaults: UserDefaults = .standard) {
    self.session = session
    self.defaults = defaults
  }

  var lastChat: Int64? { defaults.string(forKey: Self.lastChatKey).flatMap(Int64.init) }
  func rememberLastChat(_ id: Int64) { defaults.set(String(id), forKey: Self.lastChatKey) }
  func chatExists(_ id: Int64) -> Bool { (try? session.store.dialog(chatId: id)) != nil }
  func chatTitle(_ id: Int64) -> String? {
    (try? session.store.dialogItems(limit: 5000).first { $0.id == id }?.title)
  }
}
