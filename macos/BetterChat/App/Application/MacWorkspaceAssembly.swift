import QQBridgeKit
import SwiftUI
import UIKit

/// 依赖装配：在入口处把 Session 适配成各服务，再组装 ViewModel 与协调器。
/// 页面、ViewModel 都只拿到协议，便于替换为检查用的假实现。
@MainActor
enum MacWorkspaceAssembly {
  static func makeCoordinator(session: Session, model: AppModel, manualSync: MacManualSync, router: MacCommandRouter) -> MacWorkspaceCoordinator {
    let dialogs = MacDialogsViewModel(service: MacSessionConversationService(session: session), manualSync: manualSync)
    let search = MacSidebarSearchViewModel(service: MacSessionSearchService(session: session), dialogs: dialogs)
    let contacts = MacContactsViewModel(service: MacSessionContactsService(session: session))
    return MacWorkspaceCoordinator(.init(
      session: session, model: model, manualSync: manualSync, router: router,
      dialogs: dialogs, search: search, contacts: contacts,
      store: MacSessionWorkspaceStore(session: session)))
  }

  static func makeLoginController(model: AppModel) -> MacLoginController {
    let authentication = MacSessionAuthenticationService { [model] server, username, password in
      try await model.login(server: server, username: username, password: password)
    }
    return MacLoginController(viewModel: MacLoginViewModel(
      authentication: authentication, preferences: MacUserDefaultsLoginPreferences(),
      reachability: MacHTTPServerReachabilityService(), presets: MacServerPreset.standard,
      describeError: loginErrorMessage))
  }

  static func loginErrorMessage(_ error: any Error) -> String {
    if let error = error as? APIError {
      return error.isUnauthenticated ? "用户名或密码不对" : "登录失败：\(error.message)"
    }
    return "连不上服务器：\(error.localizedDescription)"
  }
}

/// 已登录工作区：协调器由应用级的 MacWorkspaceKeeper 持有，随会话（Session）存亡，不随主窗口存亡。
struct MacWorkspace: UIViewControllerRepresentable {
  let session: Session
  let manualSync: MacManualSync
  let router: MacCommandRouter
  let keeper: MacWorkspaceKeeper<MacWorkspaceCoordinator>
  @Environment(AppModel.self) private var model

  func makeUIViewController(context: Context) -> MacWorkspaceWindowHost {
    let coordinator = keeper.coordinator(for: session) {
      MacWorkspaceAssembly.makeCoordinator(session: session, model: model, manualSync: manualSync, router: router)
    }
    return MacWorkspaceWindowHost(content: coordinator.rootViewController)
  }
  func updateUIViewController(_ controller: MacWorkspaceWindowHost, context: Context) {}
}

/// 保留已登录的工作区：⌘W 关掉主窗口只是关窗，侧栏、右栏聊天页（已加载的消息、滚动位置、草稿）都留着，
/// 重开窗口时接回同一个协调器。
///
/// 2026-11-12 用户反馈：⌘W 后重开，之前看到的消息位置丢了，并且先显示占位页。原因是协调器由 SwiftUI 的
/// Representable 持有，关窗时场景断开，整个工作区随窗口的 UIHostingController 释放；重开是新建协调器，
/// 右栏从空状态页开始、聊天页重新从最新一屏加载。只有退出登录（或换了 Session）才拆掉。
@MainActor
final class MacWorkspaceKeeper<Workspace: MacKeptWorkspace> {
  private var kept: (session: ObjectIdentifier, coordinator: Workspace)?

  var coordinator: Workspace? { kept?.coordinator }

  /// 同一个 Session 复用已有工作区；换了 Session 先拆掉旧的再建新的。
  func coordinator(for session: AnyObject, make: () -> Workspace) -> Workspace {
    let id = ObjectIdentifier(session)
    if let kept, kept.session == id { return kept.coordinator }
    discard()
    let coordinator = make()
    kept = (id, coordinator)
    return coordinator
  }

  /// 退出登录：注销命令、关掉附属窗口、取消任务。
  func discard() {
    kept?.coordinator.tearDown()
    kept = nil
  }
}

/// 能被 MacWorkspaceKeeper 保留的工作区（测试用假实现）。
@MainActor
protocol MacKeptWorkspace: AnyObject {
  func tearDown()
}
extension MacWorkspaceCoordinator: MacKeptWorkspace {}

/// 每个主窗口一个的外壳：把保留下来的工作区根控制器接进这个窗口。
/// SwiftUI 只管理外壳本身；根控制器由外壳从旧窗口（已关闭的）挪过来，旧窗口晚到的拆除碰不到它。
@MainActor
final class MacWorkspaceWindowHost: UIViewController {
  let content: UIViewController

  init(content: UIViewController) {
    self.content = content
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    embed()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    embed()
  }

  /// 根控制器还挂在别的外壳上（关掉的窗口还没释放）时先摘下来再接进来。
  func embed() {
    guard content.parent !== self else { return }
    if content.parent != nil {
      content.willMove(toParent: nil)
      content.view.removeFromSuperview()
      content.removeFromParent()
    }
    addChild(content)
    content.view.frame = view.bounds
    content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(content.view)
    content.didMove(toParent: self)
  }
}

struct MacLoginPage: UIViewControllerRepresentable {
  @Environment(AppModel.self) private var model
  func makeUIViewController(context: Context) -> MacLoginController {
    MacWorkspaceAssembly.makeLoginController(model: model)
  }
  func updateUIViewController(_ controller: MacLoginController, context: Context) {}
}
