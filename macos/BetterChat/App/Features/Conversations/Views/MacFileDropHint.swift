import SwiftUI

/// 只标记消息列表的可投放区域，附件条和输入框继续保持可见。
struct MacFileDropHint: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "arrow.down.document")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("松手添加附件")
        .font(.headline)
      Text("预览后发送")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 28)
    .padding(.vertical, 22)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: 16)
        .fill(.ultraThinMaterial)
        .overlay {
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(.tint.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .padding(12)
    }
    // Catalyst 的侧栏与输入栏通过安全区避让；忽略安全区会按整窗居中，并把边框裁掉。
    .clipped()
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
  }
}
