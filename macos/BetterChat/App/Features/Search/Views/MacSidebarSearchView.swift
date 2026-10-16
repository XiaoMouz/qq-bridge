import QQBridgeKit
import SwiftUI

/// 搜索只占用左栏：结果替换会话列表，加载、失败重试与无结果都留在左栏，打开结果在右栏定位。
struct MacSidebarSearchView: View {
  let session: Session
  let viewModel: MacSidebarSearchViewModel
  let focusRequest: UUID
  let returnToSearch: () -> Void

  var body: some View {
    let groups = viewModel.groups
    VStack(spacing: 0) {
      ResultList(session: session, groups: groups, selected: viewModel.selected, focusRequest: focusRequest,
                 select: { viewModel.select($0) }, returnToSearch: returnToSearch,
                 rowAppeared: { viewModel.wantAvatar(for: $0) })
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

    func makeUIViewController(context: Context) -> MacSearchResultsController {
      MacSearchResultsController(session: session, focusRequest: focusRequest)
    }
    func updateUIViewController(_ controller: MacSearchResultsController, context: Context) {
      controller.select = select
      controller.returnToSearch = returnToSearch
      controller.rowAppeared = rowAppeared
      controller.applySidebarListInsets()
      controller.update(groups: groups, selected: selected, focusRequest: focusRequest)
    }
  }
}
