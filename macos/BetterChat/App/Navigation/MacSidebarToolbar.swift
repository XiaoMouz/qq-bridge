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
  }
  struct Actions {
    let selectSection: (MacSidebarSection) -> Void
    let refreshContacts: () -> Void
  }

  private let item: UINavigationItem
  private let actions: Actions
  private var applied: State?
  private let sections: UISegmentedControl
  private let sectionsItem: UIBarButtonItem

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
    var trailing: [UIBarButtonItem] = [sectionsItem]
    if state.section == .contacts {
      let refresh = UIBarButtonItem(title: "刷新联系人", image: UIImage(systemName: MacSymbol.sync),
                                    primaryAction: UIAction { [actions] _ in actions.refreshContacts() })
      refresh.isEnabled = !state.contactsRefreshing
      trailing.insert(refresh, at: 0)
    }
    item.leadingItemGroups = []
    item.trailingItemGroups = [UIBarButtonItemGroup(barButtonItems: trailing, representativeItem: nil)]
  }
}
