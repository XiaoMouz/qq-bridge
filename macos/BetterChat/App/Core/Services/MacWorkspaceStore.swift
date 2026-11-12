import Foundation
import QQBridgeKit

/// 工作区需要的少量本地读取与偏好：上次打开的会话及看到的位置、会话标题。协调器不直接碰数据库或 UserDefaults。
@MainActor
protocol MacWorkspaceStore {
  var lastChat: Int64? { get }
  func rememberLastChat(_ id: Int64)
  /// 上次会话里看到的消息（nil = 在最底下）；换了会话就不算数。
  func lastPosition(in id: Int64) -> Int64?
  func rememberPosition(_ seq: Int64?, in id: Int64)
  func chatExists(_ id: Int64) -> Bool
  func chatTitle(_ id: Int64) -> String?
}

@MainActor
struct MacSessionWorkspaceStore: MacWorkspaceStore {
  private static let lastChatKey = "mac.lastChat"
  /// "会话ID:seq"，只记上次那个会话。
  private static let positionKey = "mac.lastChatPosition"
  let session: Session
  let defaults: UserDefaults

  init(session: Session, defaults: UserDefaults = .standard) {
    self.session = session
    self.defaults = defaults
  }

  var lastChat: Int64? { defaults.string(forKey: Self.lastChatKey).flatMap(Int64.init) }
  func rememberLastChat(_ id: Int64) { defaults.set(String(id), forKey: Self.lastChatKey) }
  func lastPosition(in id: Int64) -> Int64? {
    guard let parts = defaults.string(forKey: Self.positionKey)?.split(separator: ":"), parts.count == 2,
          Int64(parts[0]) == id else { return nil }
    return Int64(parts[1])
  }
  func rememberPosition(_ seq: Int64?, in id: Int64) {
    if let seq { defaults.set("\(id):\(seq)", forKey: Self.positionKey) } else { defaults.removeObject(forKey: Self.positionKey) }
  }
  func chatExists(_ id: Int64) -> Bool { (try? session.store.dialog(chatId: id)) != nil }
  func chatTitle(_ id: Int64) -> String? {
    (try? session.store.dialogItems(limit: 5000).first { $0.id == id }?.title)
  }
}
