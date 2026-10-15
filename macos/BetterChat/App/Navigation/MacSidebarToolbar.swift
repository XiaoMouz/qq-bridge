import UIKit

/// 侧栏标题栏：把分区状态投射为原生 UINavigationItem。
/// 消息分区只保留系统侧栏开关；群助手返回属于列表内导航，不挤进窗口工具栏。
@MainActor
final class MacSidebarToolbar {
  struct State: Equatable {
    var section: MacSidebarSection
    var contactsRefreshing: Bool
    var showsArchived: Bool = false
  }
  struct Actions {
    let refreshContacts: () -> Void
  }

  private let item: UINavigationItem
  private let actions: Actions
  private var applied: State?

  init(item: UINavigationItem, actions: Actions) {
    self.item = item
    self.actions = actions
    item.style = .navigator
  }

  func apply(_ state: State) {
    guard state != applied else { return }
    applied = state
    item.title = state.section == .messages && state.showsArchived ? "群助手" : state.section.title
    switch state.section {
    case .messages:
      item.trailingItemGroups = []
      item.leadingItemGroups = []
    case .contacts:
      let refresh = UIBarButtonItem(title: "刷新联系人", image: UIImage(systemName: MacSymbol.sync),
                                    primaryAction: UIAction { [actions] _ in actions.refreshContacts() })
      refresh.isEnabled = !state.contactsRefreshing
      item.trailingItemGroups = [UIBarButtonItemGroup(barButtonItems: [refresh], representativeItem: nil)]
      item.leadingItemGroups = []
    case .settings:
      item.trailingItemGroups = []
      item.leadingItemGroups = []
    }
  }
}
