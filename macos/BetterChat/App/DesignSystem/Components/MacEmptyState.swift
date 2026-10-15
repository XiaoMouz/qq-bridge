import SwiftUI
import UIKit

/// 右栏无内容时的统一占位；UIKit 与 SwiftUI 两侧共用同一组文案结构。
struct MacEmptyState: Equatable {
  let title: String
  let message: String
  let symbol: String
  /// 右栏工具栏的短标题（分区名）。占位正文可能很长，不能拿来当工具栏标题；
  /// 没有它时标题栏会退回显示窗口场景标题「… — BetterChat」（M5）。
  let toolbarTitle: String

  static let chat = MacEmptyState(title: "你的对话，尽在这里", message: "选择左侧会话，或从联系人中打开聊天。", symbol: MacSymbol.emptyChat, toolbarTitle: "消息")
  static let contact = MacEmptyState(title: "联系人", message: "选择好友或群聊，查看详细资料。", symbol: MacSymbol.emptyContact, toolbarTitle: "联系人")

  var configuration: UIContentUnavailableConfiguration {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: symbol)
    config.text = title
    config.secondaryText = message
    return config
  }
}

struct MacEmptyStateView: View {
  let state: MacEmptyState
  var body: some View {
    ContentUnavailableView(state.title, systemImage: state.symbol, description: Text(state.message))
  }
}

/// 状态浮条（同步中、连接、QQ 掉线）：统一内边距与胶囊玻璃，不在内容区叠装饰玻璃。
struct MacStatusPill<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View {
    HStack(spacing: 8, content: content)
      .font(.callout)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .glassEffect(.regular, in: .capsule)
  }
}
