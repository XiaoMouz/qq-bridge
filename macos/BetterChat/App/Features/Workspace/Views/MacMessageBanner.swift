import SwiftUI

/// 桌面横幅提供独立的关闭目标，避免必须用手机的上划手势才能收起。
struct MacMessageBanner<Avatar: View>: View {
  let banner: InAppBanner
  let onOpen: () -> Void
  let onDismiss: () -> Void
  @ViewBuilder let avatar: () -> Avatar

  var body: some View {
    HStack(spacing: 8) {
      Button(action: onOpen) {
        HStack(spacing: 10) {
          avatar()
          VStack(alignment: .leading, spacing: 2) {
            Text(banner.title).font(.subheadline.bold()).lineLimit(1)
            Text(banner.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("快速回复：\(banner.title)")
      .accessibilityValue(banner.body)
      .help("打开快速回复")

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭消息横幅")
      .help("关闭消息横幅")
    }
    .padding(.leading, 16)
    .padding(.trailing, 10)
    .padding(.vertical, 12)
    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .padding(.horizontal, 10)
  }
}
