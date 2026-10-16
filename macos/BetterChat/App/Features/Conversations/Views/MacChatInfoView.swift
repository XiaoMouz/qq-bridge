import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 右侧检查器里的会话资料：群资料或对方资料，复用 iOS 页面。
/// 检查器是分栏控制器的独立一栏，不在聊天页里，所以群成员和头像在这里自己加载一份。
/// 点成员的「@」插进这个会话的草稿（和在聊天里 @ 一样）。
struct MacChatInfoView: View {
  let session: Session
  let chatId: Int64
  let mention: (Int64, String) -> Void
  @State private var dialog: Qqbridge_V1_Dialog?
  @State private var members = GroupMembers()
  @State private var avatars = AvatarBook()

  var body: some View {
    Group {
      if let dialog {
        if dialog.scene == .group {
          GroupInfoView(session: session, dialog: dialog, members: members, avatars: avatars, onMention: { id in
            mention(id, members.displayName(id) ?? String(id))
          })
        } else {
          UserProfileView(session: session, userId: dialog.peerID, groupMember: nil, conversationID: chatId)
        }
      } else {
        ProgressView()
      }
    }
    // 2026-10-17 用户反馈：资料页用的是 iOS 分组列表的浅灰底，在深色的聊天旁边整块很突兀。
    // 检查器底色和聊天一样，只留分组卡片的一点层次（子页面也继承这个设置）。
    .scrollContentBackground(.hidden)
    .background(Color(uiColor: .systemBackground))
    .task(id: chatId) {
      dialog = try? session.store.dialog(chatId: chatId)
      if let dialog, dialog.scene == .group { await members.load(session: session, groupId: dialog.peerID) }
    }
  }
}
