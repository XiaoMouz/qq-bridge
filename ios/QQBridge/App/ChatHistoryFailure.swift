import SwiftUI

struct ChatHistoryFailure: View {
  var title = "更早的消息加载失败"
  let message: String
  let retry: () -> Void
  var dismiss: (() -> Void)? = nil
  var retryLabel = "重新加载更早的消息"

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.callout.weight(.medium))
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
      }
      Spacer(minLength: 0)
      Button("重试", action: retry).buttonStyle(.bordered)
        .accessibilityLabel(retryLabel)
      if let dismiss {
        Button("关闭提示", systemImage: "xmark", action: dismiss)
          .labelStyle(.iconOnly).buttonStyle(.borderless)
          .frame(minWidth: 28, minHeight: 28)
      }
    }
    .padding(12)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal, 12)
    .padding(.top, 6)
  }
}
