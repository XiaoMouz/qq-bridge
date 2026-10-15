import Foundation

/// 侧栏底部的三个顶层分区；搜索不是分区，而是每个分区顶部的筛选。
enum MacSidebarSection: Int, CaseIterable, Hashable {
  case messages, contacts, settings

  var title: String {
    switch self { case .messages: "消息"; case .contacts: "联系人"; case .settings: "设置" }
  }
  var symbol: String {
    switch self { case .messages: MacSymbol.messages; case .contacts: MacSymbol.contacts; case .settings: MacSymbol.settings }
  }
  var selectedSymbol: String {
    switch self { case .messages: MacSymbol.messagesSelected; case .contacts: MacSymbol.contactsSelected; case .settings: MacSymbol.settingsSelected }
  }
  var searchPrompt: String {
    switch self { case .messages: "搜索消息与联系人"; case .contacts: "搜索联系人"; case .settings: "搜索设置" }
  }
  var identifier: String { "mac.tab.\(self)" }
}

/// 设置分区左栏的选项；右栏显示对应页面及其子页面。
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
  /// 搜索设置时除名称外也匹配常见说法，避免只能输入标题原文。
  var keywords: [String] {
    switch self {
    case .account: ["账号", "QQ", "登录", "扫码", "二维码", "退出", "在线"]
    case .preferences: ["偏好", "预览", "语音", "转文字"]
    case .sync: ["同步", "立即同步", "刷新", "消息"]
    case .downloads: ["下载", "目录", "文件夹", "Downloads"]
    case .storage: ["存储", "缓存", "清理", "空间"]
    case .about: ["关于", "版本", "服务", "连接"]
    }
  }
}

/// 左栏结果交给协调器的导航意图；ViewModel 只产生意图，不直接切页面。
enum MacSidebarRoute: Equatable {
  case chat(Int64)
  case message(chatId: Int64, seq: Int64)
}
