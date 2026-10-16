import Foundation

/// 侧栏的两个顶层分区，由工具栏里的分段控件切换；设置是独立窗口（⌘,），不再是分区。
/// 搜索不是分区，而是每个分区顶部的筛选。
enum MacSidebarSection: Int, CaseIterable, Hashable {
  case messages, contacts

  var title: String {
    switch self { case .messages: "消息"; case .contacts: "联系人" }
  }
  var symbol: String {
    switch self { case .messages: MacSymbol.messages; case .contacts: MacSymbol.contacts }
  }
  var selectedSymbol: String {
    switch self { case .messages: MacSymbol.messagesSelected; case .contacts: MacSymbol.contactsSelected }
  }
  var searchPrompt: String {
    switch self { case .messages: "搜索消息与联系人"; case .contacts: "搜索联系人" }
  }
  var identifier: String { "mac.tab.\(self)" }
}

/// 设置窗口顶部的标签。
enum MacSetting: String, CaseIterable, Hashable {
  case account = "账号", preferences = "偏好", sync = "同步", downloads = "下载", storage = "存储", about = "关于"
  var symbol: String {
    switch self {
    case .account: "person.crop.circle"
    case .preferences: "slider.horizontal.3"
    case .sync: "arrow.triangle.2.circlepath"
    case .downloads: "arrow.down.circle"
    case .storage: "internaldrive"
    case .about: "info.circle"
    }
  }
}

/// 左栏结果交给协调器的导航意图；ViewModel 只产生意图，不直接切页面。
enum MacSidebarRoute: Equatable {
  case chat(Int64)
  case message(chatId: Int64, seq: Int64)
}
