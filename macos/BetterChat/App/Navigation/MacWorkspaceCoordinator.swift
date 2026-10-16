import Observation
import QQBridgeKit
import UIKit

/// 工作区协调器：唯一的窗口路由所有者。决定左栏分区、右栏页面、宽窄布局下列表/详情的显示，
/// 保存联系人详情与设置窗口的页面控制器；聊天协调器按会话保留草稿。数据加载、过滤与业务请求在各 ViewModel / 服务中。
@MainActor
final class MacWorkspaceCoordinator: MacWorkspaceCommands {
  struct Dependencies {
    let session: Session
    let model: AppModel
    let manualSync: MacManualSync
    let router: MacCommandRouter
    let dialogs: MacDialogsViewModel
    let search: MacSidebarSearchViewModel
    let contacts: MacContactsViewModel
    let store: any MacWorkspaceStore
  }

  let rootViewController: MacAdaptiveSplitController
  private let model: AppModel
  private let manualSync: MacManualSync
  private let router: MacCommandRouter
  private let factory: MacPageFactory
  private let sidebar = MacSidebarViewModel()
  private let search: MacSidebarSearchViewModel
  private let contacts: MacContactsViewModel
  private let dialogsViewModel: MacDialogsViewModel
  private let dialogs: MacDialogsController
  private let chat: MacChatCoordinator
  private let detail = MacDetailContainer()
  private var toolbar: MacSidebarToolbar!
  private var settingPages: [MacSetting: UIViewController] = [:]
  private var chatInfoChat: Int64?
  private var contactPage: UIViewController?

  init(_ dependencies: Dependencies) {
    model = dependencies.model
    manualSync = dependencies.manualSync
    router = dependencies.router
    search = dependencies.search
    contacts = dependencies.contacts
    dialogsViewModel = dependencies.dialogs
    factory = MacPageFactory(session: dependencies.session, model: dependencies.model, router: dependencies.router, manualSync: dependencies.manualSync)
    dialogs = MacDialogsController(session: dependencies.session, model: dependencies.model, viewModel: dependencies.dialogs)
    chat = MacChatCoordinator(factory: factory, store: dependencies.store)
    // 先用占位初始化 sidebarRoot 所需的闭包目标，再在 self 可用后接线。
    let sidebarView = MacSidebarHost()
    rootViewController = MacAdaptiveSplitController(sidebarRoot: sidebarView, detailRoot: detail)
    sidebarView.install(factory.sidebar(MacSidebarView(
      session: dependencies.session, sidebar: sidebar, search: search, contacts: contacts, dialogs: dialogs,
      actions: MacSidebarActions(
        selectContact: { [weak self] in self?.showContact($0) }))))
    toolbar = MacSidebarToolbar(item: sidebarView.navigationItem, actions: .init(
      selectSection: { [weak self] in self?.reselectOrSelect($0) },
      refreshContacts: { [weak self] in self?.contacts.refresh() }))
    wireIntents()
    detail.show(chat.controller)
    rootViewController.appeared = { [weak self] in self?.workspaceAppeared() }
    rootViewController.hasDetail = { [weak self] in self?.currentSectionHasDetail ?? false }
    rootViewController.layoutChanged = { [weak self] in
      // UIKit 搬移完成后再更新 SwiftUI 展示状态，避免在布局回调里同步触发新的布局。
      Task { @MainActor [weak self] in
        guard let self else { return }
        sidebar.setCompactLayout(rootViewController.isCompact)
      }
    }
    observeSidebar()
    observeAppModel()
  }

  /// 会话资料检查器是否开着：跨会话、跨启动记住（和「信息」App 的详情栏一样）。
  private var chatInfoOpen: Bool {
    get { UserDefaults.standard.bool(forKey: "mac.chatInspector") }
    set { UserDefaults.standard.set(newValue, forKey: "mac.chatInspector") }
  }

  /// 退出登录 / 工作区被移除：注销命令、取消跨分区的同步与搜索任务。
  func tearDown() {
    router.detach(self)
    MacSettingsWindow.close()
    manualSync.cancel()
    search.cancel()
  }

  private func wireIntents() {
    dialogs.openChat = { [weak self] item in self?.openChat(item.id, title: item.title, composer: nil) }
    dialogs.quickReply = { [weak model] id in model?.quickReplyChat = id }
    dialogs.syncCompleted = { [weak model] in model?.showToast(AppToast(text: "会话同步完成")) }
    search.route = { [weak self] route in self?.open(route) }
  }

  private func workspaceAppeared() {
    router.attach(self)
    // 静默恢复上次会话：宽窗口右栏直接显示；窄窗口留在列表，不替用户进入详情。
    if model.pendingChat == nil, let id = chat.restorableChat { openChat(id, title: nil, composer: nil, revealDetail: false) }
    updateWindowTitle()
  }

  // MARK: 观察（只读模型，UIKit 更新放在追踪闭包之外）

  private func observeSidebar() {
    let state = withObservationTracking {
      MacSidebarToolbar.State(section: sidebar.section,
                              contactsRefreshing: contacts.isRefreshing,
                              showsArchived: dialogs.showsArchived,
                              hasUnread: sidebar.unread > 0)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeSidebar() }
    }
    toolbar.apply(state)
  }

  private func observeAppModel() {
    let state = withObservationTracking {
      (model.pendingChat, model.unreadBadge)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeAppModel() }
    }
    sidebar.setUnread(state.1)
    if let id = state.0 {
      // 通知、横幅、资料页“发消息”经 AppModel.pendingChat 进入；消费后清空，避免重复打开。
      model.pendingChat = nil
      openChat(id, composer: nil)
    }
  }

  // MARK: MacWorkspaceCommands

  var isWorkspaceVisible: Bool { rootViewController.viewIfLoaded?.window != nil }

  var canReturnToMessages: Bool {
    (rootViewController.isShowingCompactDetail || sidebar.section != .messages || sidebar.hasQueryText || dialogs.showsArchived)
      && rootViewController.presentedViewController == nil
  }

  func presentationDidDismiss() { rootViewController.presentationDidDismiss() }

  func showMessages() {
    sidebar.clearQuery(of: .messages)
    select(.messages)
  }
  func showContacts() { select(.contacts) }
  func showSettings() { MacSettingsWindow.open() }

  func toggleChatInfo() {
    chatInfoOpen = !rootViewController.isInspectorShown
    updateChatInfo()
  }

  /// 检查器跟着当前会话走；不在消息分区或没有会话时收起（开关状态保留，回来再打开）。
  private func updateChatInfo() {
    guard chatInfoOpen, sidebar.section == .messages, let id = chat.selectedChat else {
      rootViewController.showInspector(nil)
      return
    }
    if chatInfoChat != id || rootViewController.inspectorContent == nil {
      chatInfoChat = id
      rootViewController.showInspector(factory.chatInfo(id) { [weak self] userId, name in
        guard let self else { return }
        chat.draftComposer(for: id)?.insertMention(userId: userId, name: name)
      })
    } else {
      rootViewController.showInspector(rootViewController.inspectorContent)
    }
  }

  func settingsPage(_ setting: MacSetting) -> UIViewController {
    if let page = settingPages[setting] { return page }
    let page = factory.setting(setting)
    settingPages[setting] = page
    return page
  }

  func focusSidebarSearch() {
    rootViewController.revealSidebar()
    sidebar.focusSearch()
  }

  func toggleSidebar() { rootViewController.toggleSidebar() }

  func nextUnread() {
    // 先确定目标：没有未读时保留当前分区、搜索和窄窗口详情，避免无意义地弹回列表。
    guard let next = dialogsViewModel.nextUnread() else { return }
    sidebar.clearQuery(of: .messages)
    openChat(next.id, title: next.title, composer: nil)
  }

  func refreshDialogs() { dialogs.refreshDialogs() }

  func cancelSidebarNavigation() {
    // 搜索属于当前侧栏；退出筛选不切换顶层分区，也不清空右侧详情。
    if rootViewController.isShowingCompactDetail { rootViewController.showSidebar() }
    else if sidebar.hasQueryText { sidebar.clearQuery() }
    else if sidebar.section == .messages, dialogs.showsArchived { dialogs.setArchived(false) }
    else { showMessages() }
  }

  func openChat(_ id: Int64, composer: Composer?) { openChat(id, title: nil, composer: composer) }

  func draftComposer(for id: Int64) -> Composer? { chat.draftComposer(for: id) }
  func updateDraft(_ composer: Composer, for id: Int64) { chat.updateDraft(composer, for: id) }

  func requestWindowSize(width: CGFloat, height: CGFloat) {
    rootViewController.viewIfLoaded?.window?.windowScene?.requestGeometryUpdate(
      .Mac(systemFrame: CGRect(x: 120, y: 80, width: width, height: height)))
  }

  // MARK: 路由

  private func openChat(_ id: Int64, title: String?, composer: Composer?, revealDetail: Bool = true) {
    // 任何来源打开会话都以本次为准：早先在搜索里点的联系人即使稍后返回，也不能把页面切走。
    search.cancelPendingOpen()
    if rootViewController.presentedViewController != nil { rootViewController.dismiss(animated: true) }
    select(.messages, revealList: false)
    // 从群助手的搜索结果再次打开当前会话，也要恢复它所在的列表与选中行。
    dialogs.selectChat(id)
    if chat.open(id, title: title, composer: composer) { detail.show(chat.controller) }
    updateChatInfo()
    updateWindowTitle()
    if revealDetail { rootViewController.showDetail() }
  }

  private func open(_ route: MacSidebarRoute) {
    switch route {
    case .chat(let id):
      openChat(id, composer: nil)
    case .message(let id, let seq):
      model.openMessage(chatId: id, seq: seq)
      // openMessage 可能另外登记 pendingChat；这里直接打开，避免观察到后重复打开。
      if model.pendingChat == id { model.pendingChat = nil }
      openChat(id, composer: nil)
    }
  }

  /// 已在消息分区时再点“消息”：有搜索或在群助手先回普通列表，否则只滚到下一个未读。
  /// 右侧聊天、草稿与已读状态不因侧栏定位而改变。
  private func reselectOrSelect(_ section: MacSidebarSection) {
    guard section == .messages, sidebar.section == .messages else {
      select(section)
      return
    }
    if sidebar.hasQueryText || dialogsViewModel.showsArchived {
      sidebar.clearQuery()
      dialogs.setArchived(false)
    } else {
      dialogs.scrollToNextUnread()
    }
  }

  private func select(_ section: MacSidebarSection, revealList: Bool = true) {
    // 离开消息分区即放弃搜索里尚未返回的联系人打开；查询与结果保留，回来仍可继续查阅。
    if section != .messages { search.cancelPendingOpen() }
    sidebar.select(section)
    switch section {
    case .messages: detail.show(chat.controller)
    case .contacts: detail.show(contactPage ?? emptyContactPage)
    }
    updateChatInfo()
    if revealList { rootViewController.showSidebar() }
    updateWindowTitle()
  }

  private lazy var emptyContactPage = factory.empty(.contact)

  private var currentSectionHasDetail: Bool {
    switch sidebar.section {
    case .messages: chat.selectedChat != nil
    case .contacts: contactPage != nil
    }
  }

  private func showContact(_ route: ContactRoute) {
    // 侧栏重复选择不能重建右侧导航栈，否则正在浏览的群文件等子页面会丢失。
    guard sidebar.contact != route || contactPage == nil else {
      rootViewController.showDetail()
      return
    }
    sidebar.select(route)
    let page = factory.contact(route) { [weak self] in
      guard let self else { return }
      contacts.reload()
      // 删除可以在用户切换资料/分区后完成；只收尾被删除的资料，不抢走当前路由。
      guard sidebar.contact == route else { return }
      contactPage = nil
      sidebar.select(nil as ContactRoute?)
      if sidebar.section == .contacts { select(.contacts) }
    }
    contactPage = page
    detail.show(page)
    rootViewController.showDetail()
  }

  private func updateWindowTitle() {
    let title = sidebar.section == .messages ? chat.title : sidebar.section.title
    rootViewController.viewIfLoaded?.window?.windowScene?.title = "\(title) — BetterChat"
  }
}

/// 侧栏根控制器：承载 SwiftUI 侧栏并拥有自己的 navigationItem（标题与工具按钮）。
@MainActor
final class MacSidebarHost: UIViewController {
  func install(_ content: UIViewController) {
    addChild(content)
    content.view.frame = view.bounds
    content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(content.view)
    content.didMove(toParent: self)
  }
}
