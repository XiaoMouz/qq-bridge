import QQBridgeKit
import SwiftUI
import UIKit

/// 侧栏用户意图；由协调器实现路由，视图本身不切换页面、不请求数据。
struct MacSidebarActions {
  let selectContact: (ContactRoute) -> Void
}

/// 左栏：顶部系统搜索框，下面是当前分区内容（搜索时由结果替换）。分区由工具栏里的分段控件切换。
/// 会话列表与联系人列表常驻、只切换可见性，滚动位置与展开状态在分区切换后保留。
struct MacSidebarView: View {
  let session: Session
  @Bindable var sidebar: MacSidebarViewModel
  let search: MacSidebarSearchViewModel
  let contacts: MacContactsViewModel
  let dialogs: MacDialogsController
  let actions: MacSidebarActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      if sidebar.section == .messages, dialogs.showsArchived {
        ZStack {
          if !sidebar.isCompactLayout {
            Text("群助手").font(.headline).accessibilityAddTraits(.isHeader)
          }
          HStack {
            Button { dialogs.setArchived(false) } label: {
              Label("消息", systemImage: "chevron.left")
                .font(.body.weight(.medium))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("返回消息列表")
            .accessibilityLabel("返回消息列表")
            .accessibilityIdentifier("mac.archive.back")
            Spacer()
          }
        }
        .padding(.horizontal, MacMetrics.sidebarInset)
        .frame(height: 40)
        .transition(.opacity)
      }
      MacSidebarSearchField(text: $sidebar.query, prompt: sidebar.section.searchPrompt,
                            focusRequest: sidebar.searchFocusRequest, hasResults: searchingMessages && search.hasResults) {
        guard searchingMessages, search.hasResults else { return false }
        sidebar.focusResults()
        return true
      }
      .frame(height: MacMetrics.searchFieldHeight)
      .padding(.horizontal, MacMetrics.sidebarInset)
      .padding(.top, MacMetrics.searchSpacingTop).padding(.bottom, MacMetrics.searchSpacingBottom)
      ZStack {
        layer(visible: sidebar.section == .messages && !sidebar.isFiltering) {
          MacEmbeddedController(controller: dialogs)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        if searchingMessages {
          MacSidebarSearchView(session: session, viewModel: search, focusRequest: sidebar.resultsFocusRequest,
                               returnToSearch: { sidebar.focusSearch() })
        }
        layer(visible: sidebar.section == .contacts) {
          MacContactsSidebarView(viewModel: contacts, query: sidebar.query(for: .contacts),
                                 selected: sidebar.contact, select: actions.selectContact)
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: MacMetrics.transitionDuration), value: sidebar.section)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: dialogs.showsArchived)
    // 页面横向转场只在侧栏内绘制，不能越过分栏覆盖聊天内容。
    .clipped()
    .environment(\.macCompactSidebar, sidebar.isCompactLayout)
    .onChange(of: sidebar.query(for: .messages), initial: true) { _, query in search.update(query: query) }
  }

  private var searchingMessages: Bool { sidebar.section == .messages && sidebar.isFiltering }

  private func layer<Content: View>(visible: Bool, @ViewBuilder content: () -> Content) -> some View {
    content()
      .opacity(visible ? 1 : 0)
      .allowsHitTesting(visible)
      .accessibilityHidden(!visible)
  }
}

/// 把协调器持有的 UIKit 控制器嵌入 SwiftUI 布局；控制器生命周期不归视图管理。
struct MacEmbeddedController: UIViewControllerRepresentable {
  let controller: UIViewController
  func makeUIViewController(context: Context) -> UIViewController { controller }
  func updateUIViewController(_ controller: UIViewController, context: Context) {
    (controller as? MacSidebarListInsetting)?.applySidebarListInsets()
  }
}
