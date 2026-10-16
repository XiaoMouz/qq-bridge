import QQBridgeKit
import QQBridgeProto

/// 侧栏搜索所需的数据：本地联系人、服务端聊天记录检索、为联系人打开（或新建）会话。
@MainActor
protocol MacSearchService {
  func localContacts() -> [Qqbridge_V1_Peer]
  func searchMessages(_ term: String, limit: Int) async throws -> [Qqbridge_V1_Message]
  func openChat(with peer: Qqbridge_V1_Peer) async throws -> Int64
  /// 头像按需批量获取（AvatarBook 负责攒批与去重）。
  func requestAvatar(for peer: Qqbridge_V1_Peer, in avatars: AvatarBook)
  /// 聊天记录结果里的发送人（和 iOS 搜索同一套规则）。
  func senderName(_ message: Qqbridge_V1_Message) -> String
}

@MainActor
struct MacSessionSearchService: MacSearchService {
  let session: Session

  func localContacts() -> [Qqbridge_V1_Peer] {
    ((try? session.store.peers(kind: .user, friendsOnly: true)) ?? []) + ((try? session.store.peers(kind: .group)) ?? [])
  }
  func searchMessages(_ term: String, limit: Int) async throws -> [Qqbridge_V1_Message] {
    var request = Qqbridge_V1_SearchMessagesRequest()
    request.query = term
    request.limit = UInt32(limit)
    return try await session.api.messages.searchMessages(request: request, headers: session.api.headers).get().messages
  }
  func openChat(with peer: Qqbridge_V1_Peer) async throws -> Int64 {
    try await DialogActions.openChat(session, scene: peer.kind == .group ? .group : .friend, peerId: peer.peerID)
  }
  func requestAvatar(for peer: Qqbridge_V1_Peer, in avatars: AvatarBook) {
    if peer.kind == .group { avatars.wantGroup(peer.peerID, session: session) }
    else { avatars.want(peer.peerID, session: session) }
  }
  func senderName(_ message: Qqbridge_V1_Message) -> String {
    MessageSearchPager.senderName(message, session: session)
  }
}
