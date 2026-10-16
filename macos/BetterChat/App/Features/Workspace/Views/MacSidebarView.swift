import QQBridgeKit
import SwiftUI
import UIKit

/// 侧栏用户意图；由协调器实现路由，视图本身不切换页面、不请求数据。
struct MacSidebarActions {
  let selectSection: (MacSidebarSection) -> Void
  let selectContact: (ContactRoute) -> Void
}

/// 左栏：顶部系统搜索框，中间为当前分区内容（搜索时由结果替换），底部悬浮分区栏。
/// 会话列表与联系人列表常驻、只切换可见性，滚动位置与展开状态在分区切换后保留。
struct MacSidebarView: View {
  let session: Session
  @Bindable var sidebar: MacSidebarViewModel
  let search: MacSidebarSearchViewModel
  let contacts: MacContactsViewModel
  let dialogs: MacDialogsController
  let actions: MacSidebarActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 底部悬浮栏的实测高度（含外边距），供 UIKit 列表设置底部内容边距；不写死系统栏高度。
  @State private var floatingBarInset: CGFloat = 0

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
          // UIKit 会话列表铺到悬浮栏下面，内容在 Liquid Glass 后滚动；底部边距保证最后一行可滚出（F5）。
          // SwiftUI 的联系人 / 设置列表自己处理 safeAreaInset，本来就会在栏后滚动，不需要这样做。
          MacEmbeddedController(controller: dialogs, floatingBarInset: floatingBarInset)
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
      .environment(\.macFloatingBarInset, floatingBarInset)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: dialogs.showsArchived)
    // 页面横向转场只在侧栏内绘制，不能越过分栏覆盖聊天内容。
    .clipped()
    .safeAreaInset(edge: .bottom, spacing: 0) {
      MacFloatingTabBar(items: tabItems, selectedIndex: sidebar.section.rawValue) { index in
        if let section = MacSidebarSection(rawValue: index) { actions.selectSection(section) }
      }
      .padding(.horizontal, MacMetrics.sidebarInset).padding(.vertical, MacMetrics.tabBarVerticalInset)
      // 布局完成后才回调；高度只写进列表边距，不改变栏自身尺寸，不会形成布局循环。
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { floatingBarInset = $0 }
    }
    .environment(\.macCompactSidebar, sidebar.isCompactLayout)
    .onChange(of: sidebar.query(for: .messages), initial: true) { _, query in search.update(query: query) }
  }

  private var searchingMessages: Bool { sidebar.section == .messages && sidebar.isFiltering }

  private var tabItems: [MacFloatingTabBar.Item] {
    MacSidebarSection.allCases.map { section in
      MacFloatingTabBar.Item(title: section.title, symbol: section.symbol, selectedSymbol: section.selectedSymbol,
                             identifier: section.identifier, badge: section == .messages ? sidebar.unread : 0)
    }
  }

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
  /// 铺到悬浮栏下面时传入栏的实测高度；只改 UIKit 内容边距，不改 SwiftUI 状态。
  var floatingBarInset: CGFloat? = nil
  func makeUIViewController(context: Context) -> UIViewController { controller }
  func updateUIViewController(_ controller: UIViewController, context: Context) {
    if let floatingBarInset { (controller as? MacFloatingBarInsetting)?.applyFloatingBarInset(floatingBarInset) }
  }
}
