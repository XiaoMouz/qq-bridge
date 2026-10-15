import QQBridgeKit
import QQBridgeProto

struct MacContactsSnapshot {
  var friends: [Qqbridge_V1_Peer]
  var categories: [Qqbridge_V1_FriendCategory]
  var groups: [Qqbridge_V1_Peer]
}

/// 联系人：先给本地缓存（名字、头像都有），再向服务端取最新好友、分组和群聊。
@MainActor
protocol MacContactsService {
  func cached() -> MacContactsSnapshot
  func load(refresh: Bool) async throws -> MacContactsSnapshot
  func requestAvatar(for peer: Qqbridge_V1_Peer, in avatars: AvatarBook)
}

@MainActor
struct MacSessionContactsService: MacContactsService {
  let session: Session

  func cached() -> MacContactsSnapshot {
    MacContactsSnapshot(
      friends: (try? session.store.peers(kind: .user, friendsOnly: true)) ?? [],
      categories: [],
      groups: (try? session.store.peers(kind: .group)) ?? [])
  }
  func load(refresh: Bool) async throws -> MacContactsSnapshot {
    let api = session.api
    // 与 iOS 联系人页一致：刷新请求失败不阻止读取列表，列表失败才报错。
    if refresh { _ = await api.contacts.refreshContacts(request: .init(), headers: api.headers) }
    let friends = try await api.contacts.listFriends(request: .init(), headers: api.headers).get()
    let groups = try await api.contacts.listGroups(request: .init(), headers: api.headers).get().groups
    return MacContactsSnapshot(friends: friends.friends, categories: friends.categories, groups: groups)
  }
  func requestAvatar(for peer: Qqbridge_V1_Peer, in avatars: AvatarBook) {
    if peer.kind == .group { avatars.wantGroup(peer.peerID, session: session) }
    else { avatars.want(peer.peerID, session: session) }
  }
}
