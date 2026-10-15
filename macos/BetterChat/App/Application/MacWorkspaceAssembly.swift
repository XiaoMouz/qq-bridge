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

/// 已登录工作区：协调器由 SwiftUI 的 Coordinator 持有，随会话（Session）存亡。
struct MacWorkspace: UIViewControllerRepresentable {
  let session: Session
  let manualSync: MacManualSync
  let router: MacCommandRouter
  @Environment(AppModel.self) private var model

  func makeCoordinator() -> Holder { Holder() }
  func makeUIViewController(context: Context) -> MacAdaptiveSplitController {
    let coordinator = MacWorkspaceAssembly.makeCoordinator(session: session, model: model, manualSync: manualSync, router: router)
    context.coordinator.workspace = coordinator
    return coordinator.rootViewController
  }
  func updateUIViewController(_ controller: MacAdaptiveSplitController, context: Context) {}
  static func dismantleUIViewController(_ controller: MacAdaptiveSplitController, coordinator: Holder) {
    coordinator.workspace?.tearDown()
    coordinator.workspace = nil
  }
  @MainActor final class Holder {
    var workspace: MacWorkspaceCoordinator?
  }
}

struct MacLoginPage: UIViewControllerRepresentable {
  @Environment(AppModel.self) private var model
  func makeUIViewController(context: Context) -> MacLoginController {
    MacWorkspaceAssembly.makeLoginController(model: model)
  }
  func updateUIViewController(_ controller: MacLoginController, context: Context) {}
}
