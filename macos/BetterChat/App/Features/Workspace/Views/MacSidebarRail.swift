import QQBridgeKit
import QQBridgeProto
import SwiftUI

// 收起后的窄栏（2026-11-09 用户要求）：收起不是让侧栏消失，而是只留切换按钮、消息 / 群助手切换、
// 会话头像 + 角标，搜索放在底部、点开在右栏单独一页。角标有 @我 时红色、回复我时绿色，其余照常。

/// 窄栏顶部：展开侧栏，下面是消息、联系人（联系人列表要展开侧栏才放得下）。
/// 群助手和完整列表一样是会话里的一行（2026-11-09 用户更正：不单独列按钮）；在群助手里时点「消息」返回。
struct MacSidebarRailHeader: View {
  let section: MacSidebarSection
  let showsArchived: Bool
  let searching: Bool
  let actions: MacSidebarActions

  var body: some View {
    let inMessages = section == .messages && !searching
    VStack(spacing: 6) {
      MacRailButton(symbol: MacSymbol.sidebar, title: "展开侧栏（⌃⌘S）", on: false, action: actions.toggleSidebar)
        .accessibilityIdentifier("mac.rail.expand")
      Divider().padding(.horizontal, 18)
      MacRailButton(symbol: inMessages && !showsArchived ? MacSymbol.messagesSelected : MacSymbol.messages,
                    title: showsArchived ? "返回消息列表" : "消息（⌘1）", on: inMessages, action: actions.showMessages)
        .accessibilityIdentifier("mac.rail.messages")
      MacRailButton(symbol: section == .contacts ? MacSymbol.contactsSelected : MacSymbol.contacts,
                    title: "联系人（⌘2）", on: section == .contacts, action: actions.showContacts)
        .accessibilityIdentifier("mac.rail.contacts")
    }
    .padding(.top, 4)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity)
  }
}

/// 窄栏底部：搜索入口。
struct MacSidebarRailFooter: View {
  let searching: Bool
  let openSearch: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      Divider().padding(.horizontal, 18)
      MacRailButton(symbol: MacSymbol.search, title: "搜索（⌘F）", on: searching, action: openSearch)
        .accessibilityIdentifier("mac.rail.search")
    }
    .padding(.top, 2)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity)
  }
}

struct MacRailButton: View {
  let symbol: String
  let title: String
  let on: Bool
  var dot = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .frame(width: 40, height: 32)
        .background(on ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
          if dot { Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: -6, y: 5) }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel(dot ? "\(title)，有未读" : title)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/// 窄栏里的群助手：和完整列表同一个灰色图标，角标是有未读的群数（灰色，与完整列表一致）。
struct MacRailArchiveCell: View {
  let items: [DialogItem]

  var body: some View {
    let unreadChats = items.filter { $0.dialog.unreadCount > 0 }.count
    ZStack {
      Circle().fill(Color.gray.gradient)
      Image(systemName: "archivebox.fill").font(.title3).foregroundStyle(.white)
    }
    .frame(width: MacMetrics.rowAvatar, height: MacMetrics.rowAvatar)
    .overlay(alignment: .topTrailing) {
      if unreadChats > 0 {
        MacRailBadge.capsule("\(unreadChats)", color: Color(white: 0.6))
          .alignmentGuide(.top) { $0[.top] + 5 }
          .alignmentGuide(.trailing) { $0[.trailing] - 8 }
      }
    }
    .frame(maxWidth: .infinity)
    .help("群助手")
  }
}

/// 窄栏里的一行会话：只有头像，未读数压在右上角。
struct MacRailDialogCell: View {
  let item: DialogItem

  var body: some View {
    AvatarView(sha256: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID, size: MacMetrics.rowAvatar)
      .overlay(alignment: .topTrailing) {
        MacRailBadge(dialog: item.dialog, muted: item.isMuted).alignmentGuide(.top) { $0[.top] + 5 }
          .alignmentGuide(.trailing) { $0[.trailing] - 8 }
      }
      .frame(maxWidth: .infinity)
      .help(item.title)
  }
}

/// 未读角标的颜色：有人 @我 红色，回复我绿色（两者都有时 @我 优先）；
/// 其余和完整列表一样，提醒的是主题色、接收不提醒是灰色。
struct MacRailBadge: View {
  let dialog: Qqbridge_V1_Dialog
  let muted: Bool

  static func color(_ dialog: Qqbridge_V1_Dialog, muted: Bool) -> Color {
    if dialog.unreadMentions > 0 { return .red }
    if dialog.unreadReplies > 0 { return .green }
    return muted ? Color(white: 0.6) : .accentColor
  }

  var body: some View {
    if dialog.unreadCount > 0 {
      Self.capsule(dialog.unreadCount > 99 ? "99+" : "\(dialog.unreadCount)", color: Self.color(dialog, muted: muted))
    }
  }

  static func capsule(_ text: String, color: Color) -> some View {
      Text(text)
        .font(.system(size: 11, weight: .bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 18)
        .background(color, in: Capsule())
        // 白边把角标和头像分开（头像本身颜色各异）。
        .overlay(Capsule().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
        .fixedSize()
  }
}
