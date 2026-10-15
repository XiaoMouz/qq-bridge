import SwiftUI

struct MacSharedMediaEmptyState: View {
  let model: MacSharedMediaViewModel
  let files: Bool
  var body: some View {
    if model.items.isEmpty {
      if model.isLoading || (!model.hasLoaded && model.error == nil) { ProgressView() }
      else if let error = model.error {
        ContentUnavailableView {
          Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: { Text(error) } actions: {
          Button("重试加载") { model.loadMore() }
        }
      } else if model.hasMore {
        ContentUnavailableView {
          Label("当前页没有内容", systemImage: files ? "doc" : "photo.on.rectangle")
        } actions: { Button("加载更多") { model.loadMore() } }
      } else {
        ContentUnavailableView(files ? "没有文件" : "没有图片和视频", systemImage: files ? "doc" : "photo.on.rectangle")
      }
    }
  }
}

struct MacSharedMediaPagination: View {
  let model: MacSharedMediaViewModel
  var body: some View {
    if !model.items.isEmpty && (model.isLoading || model.error != nil || model.hasMore) {
      VStack(spacing: 8) {
        if model.isLoading { ProgressView("正在加载更多…") }
        else if let error = model.error {
          Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("重试加载") { model.loadMore() }
        } else if model.hasMore {
          Button("加载更多") { model.loadMore() }
        }
      }
      .frame(maxWidth: .infinity).padding()
    }
  }
}
