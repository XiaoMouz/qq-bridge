import SwiftUI

/// 群内容页面统一反馈：首屏错误提供重试，有数据时保留内容并在顶部显示状态。
struct MacGroupListStatus: ViewModifier {
  let empty: Bool
  let isLoading: Bool
  let hasLoaded: Bool
  let error: String?
  let emptyText: String
  let icon: String
  let reload: () -> Void

  func body(content: Content) -> some View {
    content
      .overlay { emptyState }
      // 有内容时的刷新 / 失败提示浮在顶部，不把列表推下去。
      .overlay(alignment: .top) {
        if !empty {
          if isLoading {
            MacFloatingRefreshing()
          } else if let error = error {
            MacFloatingError(message: error, reload: reload)
          }
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("刷新", systemImage: "arrow.clockwise") { reload() }
            .disabled(isLoading)
            .help("刷新当前页面")
        }
      }
  }

  @ViewBuilder private var emptyState: some View {
    if empty {
      if isLoading || (!hasLoaded && error == nil) { ProgressView() }
      else if let error = error {
        ContentUnavailableView {
          Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("重试") { reload() }
        }
      } else {
        ContentUnavailableView(emptyText, systemImage: icon)
      }
    }
  }
}
