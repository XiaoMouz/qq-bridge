import QQBridgeKit
import SwiftUI

/// 搜索只占用左栏：结果替换会话列表，加载、失败重试与无结果都留在左栏，打开结果在右栏定位。
struct MacSidebarSearchView: View {
  let session: Session
  let viewModel: MacSidebarSearchViewModel
  let focusRequest: UUID
  let returnToSearch: () -> Void
  @Environment(\.macFloatingBarInset) private var floatingBarInset

  var body: some View {
    let groups = viewModel.groups
    let hasStatusFooter = viewModel.isLoading || viewModel.error != nil
    VStack(spacing: 0) {
      ResultList(session: session, groups: groups, selected: viewModel.selected, focusRequest: focusRequest,
                 select: { viewModel.select($0) }, returnToSearch: returnToSearch,
                 rowAppeared: { viewModel.wantAvatar(for: $0) }, floatingBarInset: hasStatusFooter ? 0 : floatingBarInset)
        // 结果列表和会话列表一样铺到悬浮栏下面（F5）。加载 / 错误行在它下面时，列表不贴底，
        // 这一扩展不生效，加载与错误提示仍留在栏上方。
        .ignoresSafeArea(.container, edges: .bottom)
      if viewModel.isLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("搜索聊天记录…").foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MacMetrics.sidebarInset).padding(.vertical, 10)
      }
      if let error = viewModel.error {
        VStack(alignment: .leading, spacing: 8) {
          Text(error).font(.caption).foregroundStyle(.secondary)
          Button(viewModel.retryTitle) { viewModel.retry() }
            .disabled(!viewModel.canRetry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MacMetrics.sidebarInset).padding(.vertical, 10)
      }
    }
    // 无结果提示放在遵守安全区的外层，居中位置不被悬浮栏挡住。
    .overlay {
      if viewModel.showsEmptyState { ContentUnavailableView.search(text: viewModel.term) }
    }
  }

  private struct ResultList: UIViewControllerRepresentable {
    let session: Session
    let groups: [MacSidebarSearchViewModel.Group]
    let selected: MacSidebarSearchViewModel.ResultID?
    let focusRequest: UUID
    let select: (MacSidebarSearchViewModel.ResultID?) -> Void
    let returnToSearch: () -> Void
    let rowAppeared: (MacSidebarSearchViewModel.ResultID) -> Void
    let floatingBarInset: CGFloat

    func makeUIViewController(context: Context) -> MacSearchResultsController {
      MacSearchResultsController(session: session, focusRequest: focusRequest)
    }
    func updateUIViewController(_ controller: MacSearchResultsController, context: Context) {
      controller.select = select
      controller.returnToSearch = returnToSearch
      controller.rowAppeared = rowAppeared
      controller.applyFloatingBarInset(floatingBarInset)
      controller.update(groups: groups, selected: selected, focusRequest: focusRequest)
    }
  }
}
