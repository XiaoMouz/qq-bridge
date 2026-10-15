import SwiftUI

/// 公告与相册共用加载外壳，行内容和详情路由沿用共享页面。
struct MacGroupListPage<Item: Sendable, Content: View>: View {
  @State private var model: MacGroupListViewModel<Item>
  private let title: String
  private let emptyText: String
  private let icon: String
  private let content: ([Item]) -> Content

  init(service: any MacGroupListService<Item>, title: String, emptyText: String, icon: String,
       @ViewBuilder content: @escaping ([Item]) -> Content) {
    _model = State(initialValue: MacGroupListViewModel(service: service))
    self.title = title
    self.emptyText = emptyText
    self.icon = icon
    self.content = content
  }

  var body: some View {
    content(model.items)
      .modifier(MacGroupListStatus(empty: model.items.isEmpty, isLoading: model.isLoading,
                                   hasLoaded: model.hasLoaded, error: model.error,
                                   emptyText: emptyText, icon: icon, reload: { model.load() }))
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { await model.load().value }
      .onAppear { model.start() }
      .onDisappear { model.cancel() }
  }

}
