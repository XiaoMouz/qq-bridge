import QQBridgeProto
import SwiftUI

enum MacGroupFilePresentation: String, Identifiable {
  case move, forward
  var id: Self { self }
}

/// 根目录是合法目标，成功返回空目录列表不能把它隐藏成空状态。
struct MacGroupFolderPicker: View {
  @State private var model: MacGroupListViewModel<Qqbridge_V1_GroupFolder>
  let current: String
  let onCancel: () -> Void
  let onPick: (String) -> Void

  init(service: any MacGroupListService<Qqbridge_V1_GroupFolder>, current: String, onCancel: @escaping () -> Void, onPick: @escaping (String) -> Void) {
    _model = State(initialValue: MacGroupListViewModel(service: service))
    self.current = current
    self.onCancel = onCancel
    self.onPick = onPick
  }

  var body: some View {
    NavigationStack {
      List {
        row(id: "", name: "群文件（根目录）", icon: "tray.full")
        ForEach(model.items, id: \.id) { folder in
          row(id: folder.id, name: folder.name, icon: "folder.fill")
        }
      }
      .modifier(MacGroupListStatus(empty: !model.hasLoaded, isLoading: model.isLoading,
                                   hasLoaded: model.hasLoaded, error: model.error,
                                   emptyText: "没有文件夹", icon: "folder", reload: { model.load() }))
      .navigationTitle("移动到")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", action: cancel).keyboardShortcut(.cancelAction)
        }
      }
      .onAppear { model.start() }
      .onDisappear { model.cancel() }
    }
  }

  private func row(id: String, name: String, icon: String) -> some View {
    Button { onPick(id) } label: {
      HStack {
        Label(name, systemImage: icon).foregroundStyle(id == current ? .secondary : .primary)
        Spacer()
        if id == current { Text("当前位置").font(.caption).foregroundStyle(.secondary) }
      }
    }
    .disabled(id == current || !model.hasLoaded)
  }

  private func cancel() {
    model.cancel()
    // 2026-10-15 实机：嵌套页面的环境 dismiss 未关闭群文件的 sheet，由所有者收起。
    onCancel()
  }
}
