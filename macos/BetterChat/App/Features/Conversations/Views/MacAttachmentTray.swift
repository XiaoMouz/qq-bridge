import SwiftUI

/// 鼠标用户可直接翻动附件；触控板横滑与键盘访问仍使用系统 ScrollView。
struct MacAttachmentTray: View {
  @Bindable var composer: Composer
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var position = ScrollPosition(x: 0)
  @State private var offset: CGFloat = 0

  var body: some View {
    GeometryReader { geometry in
      let contentWidth = CGFloat(max(0, composer.attachments.count * 80 - 8)) + 12
      let overflow = contentWidth > geometry.size.width - 32
      let viewport = max(1, geometry.size.width - (overflow ? 64 : 32))
      let maximum = max(0, contentWidth - viewport)
      HStack(spacing: 4) {
        if overflow { scrollButton("chevron.left", title: "显示前面的附件", delta: -viewport, maximum: maximum) }
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(Array(composer.attachments.enumerated()), id: \.element.id) { index, attachment in
              MacAttachmentTile(attachment: attachment, index: index) {
                composer.attachments.removeAll { $0.id == attachment.id }
              }
            }
          }
          .padding(.top, 6)
          .padding(.bottom, 6)
          .padding(.horizontal, 6)
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, value in offset = value }
        if overflow { scrollButton("chevron.right", title: "显示后面的附件", delta: viewport, maximum: maximum) }
      }
      .padding(.horizontal, overflow ? 4 : 16)
    }
    .frame(height: 84)
  }

  private func scrollButton(_ symbol: String, title: String, delta: CGFloat, maximum: CGFloat) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
        let step = max(80, abs(delta) - 80)
        position.scrollTo(x: min(maximum, max(0, offset + (delta < 0 ? -step : step))))
      }
    } label: {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        .frame(width: 24, height: 72).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .help(title)
    .disabled(delta < 0 ? offset <= 1 : offset >= maximum - 1)
  }
}
