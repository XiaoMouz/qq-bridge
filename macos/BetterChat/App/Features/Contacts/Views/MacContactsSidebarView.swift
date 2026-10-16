import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 联系人左栏：系统分段选择“好友 / 群聊”，系统列表选择驱动右栏资料。
/// 键盘上下移动与鼠标点击共用同一份选中状态；重复选择不重建右栏，正在浏览的子页面得以保留。
struct MacContactsSidebarView: View {
  let viewModel: MacContactsViewModel
  let query: String
  let selected: ContactRoute?
  let select: (ContactRoute) -> Void

  var body: some View {
    let content = viewModel.content(matching: query)
    List(selection: selection) {
      switch content {
      case .flat(let people):
        ForEach(people, id: \.peerID) { row($0) }
      case .categories(let categories):
        ForEach(categories) { category in
          DisclosureGroup(isExpanded: expanded(category.id)) {
            ForEach(category.people, id: \.peerID) { row($0) }
          } label: {
            HStack {
              Text(category.title).font(.headline)
              Spacer()
              Text("\(category.people.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            // 系统展开箭头与分组名之间留出间距。
            .padding(.leading, 8)
          }
        }
      }
    }
    .macSidebarList()
    .safeAreaInset(edge: .top, spacing: 0) {
      Picker("联系人类型", selection: Binding(get: { viewModel.showsGroups }, set: { viewModel.showsGroups = $0 })) {
        Text("好友 \(viewModel.friends.count)").tag(false)
        Text("群聊 \(viewModel.groups.count)").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, MacMetrics.sidebarInset).padding(.bottom, MacMetrics.searchSpacingBottom)
    }
    .overlay {
      if viewModel.showsLoadError, let error = viewModel.error {
        VStack(spacing: 12) {
          ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
          Button("重试") { viewModel.refresh() }
        }
      } else if viewModel.isEmpty(matching: query) {
        ContentUnavailableView.search(text: query).allowsHitTesting(false)
      }
    }
    .onAppear { viewModel.start() }
  }

  private var selection: Binding<ContactRoute?> {
    // 让列表管理键盘与鼠标选择，右侧详情和行高亮使用同一份状态。
    Binding(get: { selected }, set: { route in if let route { select(route) } })
  }

  private func expanded(_ id: Int32) -> Binding<Bool> {
    Binding(get: { viewModel.expanded.contains(id) }, set: { viewModel.setExpanded(id, $0) })
  }

  private func row(_ peer: Qqbridge_V1_Peer) -> some View {
    MacSidebarRow(title: MacContactsViewModel.name(peer), subtitle: viewModel.subtitle(for: peer),
                  avatar: viewModel.avatar(for: peer))
      .tag(peer.kind == .group ? ContactRoute.group(peer.peerID) : ContactRoute.user(peer.peerID))
      .onAppear { viewModel.wantAvatar(peer) }
  }
}
