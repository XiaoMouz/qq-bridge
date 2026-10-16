import QQBridgeKit
import SwiftUI
import UIKit

/// 页面工厂：统一注入 AppModel 与 Session 环境，创建右栏页面和弹窗；不保存任何路由状态。
@MainActor
struct MacPageFactory: MacChatPageBuilding {
  let session: Session
  let model: AppModel
  let router: MacCommandRouter
  let manualSync: MacManualSync

  func host<V: View>(_ content: V) -> UIViewController {
    let controller = MacHostingController(rootView: content.environment(model).environment(\.session, session)
      .environment(\.macFullScreenCoverDidDismiss, { [weak router] in router?.workspace?.presentationDidDismiss() }))
    controller.view.backgroundColor = .clear
    return controller
  }

  /// 与其他右栏页面相同，经 NavigationStack 投射工具栏标题；窗口场景标题仍由协调器写入，供窗口菜单使用。
  func empty(_ state: MacEmptyState) -> UIViewController {
    host(NavigationStack {
      MacEmptyStateView(state: state)
        .navigationTitle(state.toolbarTitle)
        .navigationBarTitleDisplayMode(.inline)
    })
  }

  /// Catalyst 构建的 Info.plist 只有 CFBundleIconFile / CFBundleIconName，没有 iOS 的 CFBundleIcons，
  /// 共享 AboutView 的查找拿到空图（M4，2026-10-14 用 plutil 核对）。project.yml 把原始 AppIcon.png
  /// 作为单独资源打进包里，这里按文件路径明确读取，不依赖 UIImage(named:) 能否取到 appiconset。
  static var appIcon: UIImage? {
    Bundle.main.path(forResource: "AppIcon", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
  }

  func chat(_ id: Int64, draft: MacChatDraft) -> UIViewController {
    host(MacChatPage(session: session, chatId: id, draft: draft)
      .environment(\.macToggleChatInfo, { [weak router] in router?.workspace?.toggleChatInfo() }))
  }

  /// 检查器栏里的会话资料；有自己的导航栈（查找聊天记录、群公告等在检查器里推入）。
  func chatInfo(_ id: Int64, mention: @escaping (Int64, String) -> Void) -> UIViewController {
    let controller = UIHostingController(rootView: NavigationStack {
      MacChatInfoView(session: session, chatId: id, mention: mention)
    }.environment(model).environment(\.session, session))
    controller.view.backgroundColor = .clear
    return controller
  }

  /// 设置窗口的页面：窗口工具栏已经写明是哪一页，根页面不再显示自己的标题栏；子页面（存储明细等）照常有返回。
  func setting(_ setting: MacSetting) -> UIViewController {
    switch setting {
    case .account: host(SettingsView(session: session, accountOnly: true))
    case .preferences: host(NavigationStack { PreferencesView().macSettingsRoot() })
    case .sync: host(NavigationStack { MacSyncSettingsView(sync: manualSync, synchronize: { [weak router] in router?.workspace?.refreshDialogs() }).macSettingsRoot() })
    case .downloads: host(NavigationStack { MacDownloadSettingsView().macSettingsRoot() })
    case .storage: host(NavigationStack { StorageView(session: session).macSettingsRoot() })
    case .about: host(NavigationStack { AboutView(session: session, icon: Self.appIcon).macSettingsRoot() })
    }
  }

  func contact(_ route: ContactRoute, onDeleted: @escaping () -> Void) -> UIViewController {
    switch route {
    case .user(let id):
      host(NavigationStack {
        UserProfileView(session: session, userId: id, groupMember: nil, contactActions: true, onDeleted: onDeleted)
      })
    case .group(let id):
      host(NavigationStack { MacContactGroupView(session: session, groupID: id) })
    }
  }

  func sidebar<V: View>(_ content: V) -> UIViewController {
    let controller = UIHostingController(rootView: content.environment(model).environment(\.session, session)
      .environment(\.macFullScreenCoverDidDismiss, { [weak router] in router?.workspace?.presentationDidDismiss() }))
    controller.view.backgroundColor = .clear
    return controller
  }
}

extension View {
  /// 设置窗口里的根页面：隐藏 NavigationStack 自己的标题栏（标题已在窗口工具栏）。
  func macSettingsRoot() -> some View { toolbarVisibility(.hidden, for: .navigationBar) }
}
