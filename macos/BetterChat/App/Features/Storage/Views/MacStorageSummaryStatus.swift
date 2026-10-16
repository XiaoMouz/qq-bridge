import SwiftUI

struct MacStorageSummaryStatus<Value: Sendable>: ViewModifier {
  let model: MacStorageSummaryModel<Value>

  func body(content: Content) -> some View {
    content
      .overlay {
        if model.value == nil {
          if let error = model.error {
            ContentUnavailableView {
              Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: { Button("重试") { model.reload() } }
          } else { ProgressView("正在加载…") }
        }
      }
      // 有数据时的刷新 / 失败提示浮在顶部，不把内容推下去。
      .overlay(alignment: .top) {
        if model.value != nil {
          if model.isLoading {
            MacFloatingRefreshing()
          } else if let error = model.error {
            MacFloatingError(message: error) { model.reload() }
          }
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("刷新", systemImage: "arrow.clockwise") { model.reload() }
            .disabled(model.isLoading).help("刷新存储统计")
        }
      }
      .onAppear { model.start() }
      .onDisappear { model.cancel() }
  }
}
