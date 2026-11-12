import UIKit

/// 侧栏标题栏：把分区状态投射为原生 UINavigationItem。
/// 2026-10-17：分区切换从侧栏底部的 iOS 式标签栏挪到这里，用系统分段控件（和「访达」「邮件」工具栏里的一样）；
/// 消息分区有未读时，在联系人分区里「消息」图标换成带圆点的样式。群助手返回属于列表内导航，不挤进窗口工具栏。
@MainActor
final class MacSidebarToolbar {
  struct State: Equatable {
    var section: MacSidebarSection
    var contactsRefreshing: Bool
    var showsArchived: Bool = false
    var hasUnread = false
    /// 窄栏：标题栏放不下按钮，切换按钮和分区都在栏内。
    var rail = false
    /// 「通知手机」（PhoneNotifications）：手动开关、是否被在线 Mac 自动停用、本机选项。
    var phoneManualOn = true
    var phoneAutoOff = false
    var autoMuteHere = false
  }
  struct Actions {
    let selectSection: (MacSidebarSection) -> Void
    let refreshContacts: () -> Void
    let toggleSidebar: () -> Void
    var setPhoneNotifications: (Bool) -> Void = { _ in }
    var setAutoMuteHere: (Bool) -> Void = { _ in }
  }

  private let item: UINavigationItem
  private let actions: Actions
  private var applied: State?
  private let sections: UISegmentedControl
  private let sectionsItem: UIBarButtonItem
  private let sidebarItem: UIBarButtonItem

  init(item: UINavigationItem, actions: Actions) {
    self.item = item
    self.actions = actions
    sections = UISegmentedControl(items: MacSidebarSection.allCases.map { UIImage(systemName: $0.symbol) as Any })
    for section in MacSidebarSection.allCases {
      sections.imageForSegment(at: section.rawValue)?.accessibilityLabel = section.title
    }
    sections.selectedSegmentIndex = MacSidebarSection.messages.rawValue
    sections.addAction(UIAction { [weak sections, actions] _ in
      guard let index = sections?.selectedSegmentIndex, let section = MacSidebarSection(rawValue: index) else { return }
      actions.selectSection(section)
    }, for: .valueChanged)
    sections.toolTip = "消息（⌘1）/ 联系人（⌘2）"
    sectionsItem = UIBarButtonItem(customView: sections)
    sectionsItem.title = "分区"
    // 系统的侧栏按钮会把侧栏整个藏起来（2026-11-09 改成收成窄栏），换成自己的按钮。
    sidebarItem = UIBarButtonItem(title: "收起侧栏（⌃⌘S）", image: UIImage(systemName: MacSymbol.sidebar),
                                  primaryAction: UIAction { [actions] _ in actions.toggleSidebar() })
    item.style = .navigator
  }

  func apply(_ state: State) {
    guard state != applied else { return }
    applied = state
    // 标题由分段控件表达，不再重复写「消息」「联系人」。
    item.title = nil
    if sections.selectedSegmentIndex != state.section.rawValue { sections.selectedSegmentIndex = state.section.rawValue }
    let messageSymbol = state.hasUnread && state.section != .messages ? "message.badge" : MacSymbol.messages
    sections.setImage(UIImage(systemName: messageSymbol), forSegmentAt: MacSidebarSection.messages.rawValue)
    sections.imageForSegment(at: MacSidebarSection.messages.rawValue)?.accessibilityLabel = state.hasUnread ? "消息，有未读" : "消息"
    guard !state.rail else {
      item.leadingItemGroups = []
      item.trailingItemGroups = []
      return
    }
    var trailing: [UIBarButtonItem] = [sectionsItem]
    if state.section == .contacts {
      let refresh = UIBarButtonItem(title: "刷新联系人", image: UIImage(systemName: MacSymbol.sync),
                                    primaryAction: UIAction { [actions] _ in actions.refreshContacts() })
      refresh.isEnabled = !state.contactsRefreshing
      trailing.insert(refresh, at: 0)
    }
    item.leadingItemGroups = [UIBarButtonItemGroup(barButtonItems: [sidebarItem, phoneItem(state)], representativeItem: nil)]
    item.trailingItemGroups = [UIBarButtonItemGroup(barButtonItems: trailing, representativeItem: nil)]
  }

  /// 「通知手机」放在侧栏顶部（2026-11-12 用户要求比设置页更好找）：图标表示手机现在收不收通知，点开是菜单。
  private func phoneItem(_ state: State) -> UIBarButtonItem {
    let phoneOn = state.phoneManualOn && !state.phoneAutoOff
    let manual = UIAction(title: "通知手机", state: state.phoneManualOn ? .on : .off) { [actions] _ in
      actions.setPhoneNotifications(!state.phoneManualOn)
    }
    let auto = UIAction(title: "本机在线时自动停用", state: state.autoMuteHere ? .on : .off) { [actions] _ in
      actions.setAutoMuteHere(!state.autoMuteHere)
    }
    var children: [UIMenuElement] = [manual, auto]
    if state.phoneManualOn && state.phoneAutoOff {
      children.insert(UIAction(title: "Mac 在线，手机通知已暂停", attributes: .disabled) { _ in }, at: 0)
    }
    let menu = UIMenu(title: phoneOn ? "手机会收到新消息通知" : "手机不收新消息通知", children: children)
    let button = UIBarButtonItem(title: "通知手机", image: UIImage(systemName: phoneOn ? "iphone" : "iphone.slash"), menu: menu)
    button.accessibilityValue = phoneOn ? "开" : "关"
    return button
  }
}
