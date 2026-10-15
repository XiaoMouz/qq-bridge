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
      .safeAreaInset(edge: .top, spacing: 0) {
        if model.value != nil {
          if model.isLoading {
            ProgressView("正在刷新…").frame(maxWidth: .infinity).padding(8).background(.bar)
          } else if let error = model.error {
            HStack(spacing: 12) {
              Text(error).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              Button("重试") { model.reload() }.fixedSize()
            }.padding(12).background(.bar)
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
