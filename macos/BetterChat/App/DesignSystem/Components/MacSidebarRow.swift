import QQBridgeKit
import SwiftUI

/// 侧栏通用行：头像 + 主标题 + 副标题 + 尾部信息。搜索结果与联系人使用同一套间距和字号。
struct MacSidebarRow: View {
  let title: String
  var subtitle: String? = nil
  var trailing: String? = nil
  var avatar: MacAvatar? = nil
  var avatarSize: CGFloat = MacMetrics.rowAvatar
  var busy = false
  var subtitleLines = 1
  /// 行处于选中强调（系统强调色底）时，副标题与时间改用主前景层级。
  /// 用层级而不是固定颜色：非活动窗口、高对比度下由系统决定实际颜色。
  var emphasized = false
  /// 副标题里加粗、着色的搜索词。
  var highlight: String? = nil

  private var detailStyle: HierarchicalShapeStyle { emphasized ? .primary : .secondary }

  var body: some View {
    HStack(spacing: MacMetrics.rowSpacing) {
      if let avatar {
        AvatarView(sha256: avatar.sha256, title: avatar.title, seed: avatar.seed, size: avatarSize)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(title).lineLimit(1)
          if let trailing {
            Spacer(minLength: 4)
            Text(trailing).font(.caption).foregroundStyle(detailStyle).monospacedDigit()
          }
        }
        if let subtitle, !subtitle.isEmpty {
          Text(highlighted(subtitle)).font(.caption).foregroundStyle(detailStyle).lineLimit(subtitleLines)
        }
      }
      Spacer(minLength: 0)
      if busy { ProgressView().controlSize(.small) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private func highlighted(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    guard let term = highlight?.trimmingCharacters(in: .whitespaces), !term.isEmpty else { return out }
    var cursor = out.startIndex
    while cursor < out.endIndex, let range = out[cursor...].range(of: term, options: .caseInsensitive) {
      out[range].font = .caption.bold()
      // 选中行是强调色底：不再着色，只加粗。
      if !emphasized { out[range].foregroundColor = .accentColor }
      cursor = range.upperBound
    }
    return out
  }
}

/// 头像所需的纯值；sha256 为空时由所属 ViewModel 按需获取。
struct MacAvatar: Equatable {
  let sha256: String?
  let title: String
  let seed: Int64
}

extension View {
  /// 侧栏里的 SwiftUI 列表：系统侧栏样式（圆角选中态）。2026-10-17 去掉窄窗口单栏模式后只剩这一种。
  func macSidebarList() -> some View { listStyle(.sidebar).scrollContentBackground(.hidden) }
}
