import SwiftUI

/// 页面顶部浮着的「正在刷新…」：不参与布局，内容不会被推上推下。
struct MacFloatingRefreshing: View {
  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("正在刷新…").font(.callout)
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
    .glassEffect(.regular, in: Capsule())
    .padding(.top, 8)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}

/// 页面顶部浮着的刷新失败提示（已有内容时用；首屏失败由页面中间的空状态处理）。
struct MacFloatingError: View {
  let message: String
  let reload: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("重试", action: reload).fixedSize()
    }
    .padding(12)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .padding(.horizontal, 12).padding(.top, 8)
    .frame(maxWidth: MacMetrics.statusMaxWidth)
    .transition(.move(edge: .top).combined(with: .opacity))
  }
}
