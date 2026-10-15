import QQBridgeProto
import SwiftUI

struct MacEssenceActions {
  let requestThumbnail: (Int64, UInt32) -> Void
}

struct MacGroupEssencePage<Content: View>: View {
  @State private var model: MacGroupEssenceViewModel
  private let content: ([Qqbridge_V1_GroupEssence], MacEssenceActions) -> Content

  init(service: any MacGroupEssenceService,
       @ViewBuilder content: @escaping ([Qqbridge_V1_GroupEssence], MacEssenceActions) -> Content) {
    _model = State(initialValue: MacGroupEssenceViewModel(service: service))
    self.content = content
  }

  var body: some View {
    content(model.items, MacEssenceActions(requestThumbnail: model.requestThumbnail))
      .modifier(MacGroupListStatus(empty: model.items.isEmpty, isLoading: model.isLoading,
                                   hasLoaded: model.hasLoaded, error: model.error,
                                   emptyText: "没有群精华", icon: "star", reload: { model.load() }))
      .navigationTitle("群精华")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { await model.load().value }
      .onAppear { model.start() }
      .onDisappear { model.cancel() }
  }
}
