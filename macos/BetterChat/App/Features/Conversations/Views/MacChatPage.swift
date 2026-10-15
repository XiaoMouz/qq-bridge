import QQBridgeKit
import SwiftUI

/// 每个聊天的进程内状态：协调器按会话持有，切换会话、分区和布局时保留草稿，不缓存历史页面。
@MainActor
@Observable
final class MacChatDraft {
  var request = UUID()
  var composer = Composer()
}

/// 右栏聊天页：复用 iOS ChatScreen（资料、群文件、媒体、转发、回应、语音、通话入口都在其中）。
struct MacChatPage: View {
  let session: Session
  let chatId: Int64
  let draft: MacChatDraft

  var body: some View {
    NavigationStack {
      ChatScreen(session: session, chatId: chatId, navigationRequest: draft.request, suppliedComposer: draft.composer)
    }
  }
}

/// 使用系统标题；输入状态只在到期时触发一次刷新（共享 ChatScreen 在 Catalyst 下使用）。
struct MacChatTitle: ViewModifier {
  let title: String
  let memberCount: UInt32?
  let typingUntil: Date?

  func body(content: Content) -> some View {
    TimelineView(.explicit(typingUntil.map { [$0] } ?? [])) { context in
      let detail = subtitle(at: context.date)
      // Catalyst 原生工具栏不显示 UINavigationItem.subtitle；并入标题以保留人数与输入状态。
      content.navigationTitle(detail.isEmpty ? title : "\(title) · \(detail)")
    }
  }
  private func subtitle(at date: Date) -> String {
    if let typingUntil, typingUntil > date { return "正在输入…" }
    if let memberCount, memberCount > 0 { return "\(memberCount) 人" }
    return ""
  }
}
