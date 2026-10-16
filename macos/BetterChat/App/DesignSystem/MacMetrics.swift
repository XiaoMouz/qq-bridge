import CoreGraphics
import Foundation
import UIKit

/// 侧栏、标题栏与列表共用的尺寸。iMessage 式的密度靠统一数值保证，各页面不再各写一份。
enum MacMetrics {
  /// 2026-10-14 实机：低于该宽度时并排两栏挤压聊天输入区，改为单栏导航。
  static let compactWidth: CGFloat = 760
  static let minimumWindow = CGSize(width: 440, height: 480)

  static let sidebarPreferredWidth: CGFloat = 310
  static let sidebarMinimumWidth: CGFloat = 260
  static let sidebarMaximumWidth: CGFloat = 420

  /// 搜索框、分段选择器与列表行使用同一条水平内边距，左侧边缘对齐。
  static let sidebarInset: CGFloat = 12
  static let searchFieldHeight: CGFloat = 32
  static let searchSpacingTop: CGFloat = 4
  static let searchSpacingBottom: CGFloat = 8

  /// 会话、群助手、联系人、搜索结果的头像与间距同一组数值，切换分区时文字起点不跳动。
  /// 会话行三行预览时头像放大到 rowTallAvatar（与 iOS 的放大规则一致）。
  static let rowAvatar: CGFloat = 40
  static let rowTallAvatar: CGFloat = 48
  static let rowHorizontalMargin: CGFloat = 10
  static let rowVerticalMargin: CGFloat = 8
  static let rowSpacing: CGFloat = 10
  /// 传给共享 DialogRow / ArchiveRow 的尺寸；iOS 调用方不传，保持原有 48/56、12。
  static let dialogRow = DialogRowStyle(avatar: rowAvatar, tallAvatar: rowTallAvatar, spacing: rowSpacing)
  static let settingsIconWidth: CGFloat = 22

  /// 输入区与工具栏符号的统一字号。
  static let toolbarSymbolPointSize: CGFloat = 17
  static let composerButton = CGSize(width: 36, height: 40)

  static let statusMaxWidth: CGFloat = 580
  /// 新消息横幅：固定宽度，浮在窗口右上角（和系统通知的宽度相近）。
  static let messageBannerWidth: CGFloat = 340
  static let transitionDuration: TimeInterval = 0.18
}

/// SF Symbols 名称集中管理，标签栏、菜单与空状态使用同一套图标。
enum MacSymbol {
  static let messages = "message"
  static let messagesSelected = "message.fill"
  static let contacts = "person.2"
  static let contactsSelected = "person.2.fill"
  static let settings = "gearshape"
  static let settingsSelected = "gearshape.fill"
  static let sync = "arrow.clockwise"
  static let archive = "tray"
  static let back = "chevron.backward"
  static let search = "magnifyingglass"
  static let sidebar = "sidebar.left"
  static let attach = "plus"
  static let emptyChat = "bubble.left.and.bubble.right"
  static let emptyContact = "person.crop.circle"
}
