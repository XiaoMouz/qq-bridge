import QQBridgeProto

/// 好友 / 群的展示文字。纯函数，不依赖任何视图类型，供搜索与联系人 ViewModel 共用。
/// 规则与 iOS 联系人、搜索页一致：备注 > 昵称 > 号码。
enum MacPeerPresentation {
  static func name(_ peer: Qqbridge_V1_Peer) -> String {
    !peer.remark.isEmpty ? peer.remark : (!peer.name.isEmpty ? peer.name : String(peer.peerID))
  }

  /// 搜索结果副标题：群显示群号；有备注的好友补上原昵称。
  static func searchSubtitle(_ peer: Qqbridge_V1_Peer) -> String {
    if peer.kind == .group { return "群 \(String(peer.peerID))" }
    return !peer.remark.isEmpty && !peer.name.isEmpty ? "\(peer.name) · QQ \(String(peer.peerID))" : "QQ \(String(peer.peerID))"
  }

  /// 联系人列表副标题：群显示人数，好友显示签名。
  static func contactSubtitle(_ peer: Qqbridge_V1_Peer) -> String? {
    if peer.kind == .group { return peer.memberCount > 0 ? "\(peer.memberCount) 人" : nil }
    return peer.sign.isEmpty ? nil : peer.sign
  }

  /// 名称、昵称、备注或号码是否包含关键词。
  static func matches(_ peer: Qqbridge_V1_Peer, _ term: String) -> Bool {
    peer.name.localizedCaseInsensitiveContains(term) || peer.remark.localizedCaseInsensitiveContains(term)
      || String(peer.peerID).contains(term)
  }

  /// 同一个好友 / 群在会话与联系人两组结果中的去重键（与 iOS `searchKey` 规则相同）。
  static func key(_ peer: Qqbridge_V1_Peer) -> String { "\(peer.kind == .group ? 2 : 1):\(peer.peerID)" }
  static func key(isGroup: Bool, peerID: Int64) -> String { "\(isGroup ? 2 : 1):\(peerID)" }
}

/// 聊天记录搜索结果的展示键与文字（同样不依赖视图类型）。
enum MacMessagePresentation {
  static func key(_ message: Qqbridge_V1_Message) -> String { "\(message.chatID):\(message.seq)" }
}
