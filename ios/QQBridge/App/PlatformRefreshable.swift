import SwiftUI

extension View {
  /// 桌面需要可点击入口；刷新动作仍由各页面提供，iOS 保留原生下拉刷新。
  func platformRefreshable(action: @escaping @Sendable () async -> Void) -> some View {
    #if targetEnvironment(macCatalyst)
    toolbar {
      ToolbarItem(placement: .topBarTrailing) { MacRefreshButton() }
    }
    .refreshable(action: action)
    #else
    refreshable(action: action)
    #endif
  }
}

#if targetEnvironment(macCatalyst)
private struct MacRefreshButton: View {
  @Environment(\.refresh) private var refresh
  @State private var refreshing = false

  var body: some View {
    Button { refreshing = true } label: {
      if refreshing {
        ProgressView().controlSize(.small)
      } else {
        Label("刷新", systemImage: "arrow.clockwise")
      }
    }
    .accessibilityLabel(refreshing ? "正在刷新" : "刷新")
    .help("刷新当前页面")
    .disabled(refreshing || refresh == nil)
    .task(id: refreshing) {
      guard refreshing else { return }
      await refresh?()
      if !Task.isCancelled { refreshing = false }
    }
    .onDisappear { refreshing = false }
  }
}
#endif
