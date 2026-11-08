import QQBridgeKit
import SwiftUI

/// 侧栏收成窄栏时的搜索（2026-11-09 用户要求「搜索变成单独页面」）：在右栏单独一页，
/// 和完整侧栏共用同一个搜索词、同一个 MacSidebarSearchViewModel，展开侧栏后结果仍在。
struct MacSearchPage: View {
  let session: Session
  let sidebar: MacSidebarViewModel
  let search: MacSidebarSearchViewModel

  var body: some View {
    let query = Binding(get: { sidebar.query(for: .messages) }, set: { sidebar.setQuery($0, for: .messages) })
    let searching = !query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    VStack(spacing: 0) {
      MacSidebarSearchField(text: query, prompt: MacSidebarSection.messages.searchPrompt,
                            focusRequest: sidebar.searchFocusRequest, hasResults: searching && search.hasResults,
                            identifier: "mac.search.page") {
        guard searching, search.hasResults else { return false }
        sidebar.focusResults()
        return true
      }
      .frame(height: MacMetrics.searchFieldHeight)
      .padding(.horizontal, MacMetrics.sidebarInset)
      .padding(.top, 10)
      .padding(.bottom, MacMetrics.searchSpacingBottom)
      if searching {
        MacSidebarSearchView(session: session, viewModel: search, focusRequest: sidebar.resultsFocusRequest,
                             returnToSearch: { sidebar.focusSearch() })
      } else {
        ContentUnavailableView("搜索", systemImage: MacSymbol.search,
                               description: Text("搜索会话、联系人和聊天记录"))
          .frame(maxHeight: .infinity)
      }
    }
    // 结果行按侧栏设计，太宽了不好看；居中限宽。
    .frame(maxWidth: 640)
    .frame(maxWidth: .infinity)
    .navigationTitle("搜索")
    .navigationBarTitleDisplayMode(.inline)
  }
}
