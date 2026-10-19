import QQBridgeKit
import SwiftUI
import UIKit

/// 媒体只借用当前账号的会话，不建立第二套工作区、同步连接或聊天草稿。
@MainActor
final class MacMediaWindows {
  static let shared = MacMediaWindows()
  static let activityType = "com.xiaomouz.betterchat.mac.media"
  static let configurationName = "Media"

  enum Content {
    case message(MediaTarget, Session, Int64)
    case gallery(URLGallery)

    /// 图片和视频各用一个窗口（2026-10-19 用户要求）：再点同类媒体就换掉窗口里正在看的。
    enum Kind { case image, video }
    var kind: Kind {
      switch self {
      case .message(let target, _, _): target.kind == .video ? .video : .image
      case .gallery(let gallery): gallery.items.contains { if case .video = $0 { true } else { false } } ? .video : .image
      }
    }

    var title: String {
      switch self {
      case .message(let target, _, _): target.kind == .video ? "视频 · BetterChat" : "图片 · BetterChat"
      case .gallery(let gallery):
        gallery.items.contains { if case .video = $0 { true } else { false } } ? "媒体 · BetterChat" : "图片 · BetterChat"
      }
    }
  }

  private var pending: [String: Content] = [:]
  typealias Activate = (NSUserActivity, @escaping @MainActor () -> Void) -> Void
  private let activate: Activate
  private let reportFailure: () -> Void

  init(activate: @escaping Activate = { activity, failed in
    var request = UISceneSessionActivationRequest(role: .windowApplication)
    request.userActivity = activity
    UIApplication.shared.activateSceneSession(for: request) { _ in Task { @MainActor in failed() } }
  }, reportFailure: @escaping () -> Void = {
    AppModel.shared.showToast(AppToast(text: "无法打开媒体窗口，请重试"))
  }) {
    self.activate = activate
    self.reportFailure = reportFailure
  }

  func open(_ content: Content) {
    // 同类窗口已开着：换内容并拉到前面，不再新开（按场景委托找：代码里新建的场景 configuration.name 是 nil）。
    if let session = UIApplication.shared.openSessions.first(where: { ($0.scene?.delegate as? MacMediaSceneDelegate)?.kind == content.kind }),
       let delegate = session.scene?.delegate as? MacMediaSceneDelegate {
      delegate.show(content)
      UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
      return
    }
    let id = UUID().uuidString
    pending[id] = content
    let activity = NSUserActivity(activityType: Self.activityType)
    activity.userInfo = ["mediaWindowID": id]
    activity.targetContentIdentifier = "media:\(id)"
    activate(activity) { [weak self] in
      guard let self, pending.removeValue(forKey: id) != nil else { return }
      reportFailure()
    }
  }

  func take(_ activities: Set<NSUserActivity>) -> Content? {
    guard let activity = activities.first(where: { $0.activityType == Self.activityType }),
          let id = activity.userInfo?["mediaWindowID"] as? String else { return nil }
    return pending.removeValue(forKey: id)
  }

  func closeAll() {
    cancelPending()
    // 按场景委托找：代码里新建的场景 configuration.name 读回来是 nil（2026-10-18 实机）。
    for session in UIApplication.shared.openSessions where session.scene?.delegate is MacMediaSceneDelegate {
      (session.scene?.delegate as? MacMediaSceneDelegate)?.invalidate()
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
  }

  func cancelPending() { pending.removeAll() }
}

/// 场景拥有关闭与资源释放；关闭原聊天、切换标签都不会误关已经拉出的媒体。
@MainActor
final class MacMediaWindowContext {
  weak var scene: UIWindowScene?
  /// 右键菜单：查看器给出当前这张图的菜单（2026-10-19 实机：加在缩放视图上的右键交互收不到右键，
  /// 改加在窗口根视图上，由查看器提供内容）。
  var menu: (() -> UIMenu?)?
  private var cleanups: [String: () -> Void] = [:]
  func registerCleanup(_ key: String, action: @escaping () -> Void) { cleanups[key] = action }
  func releaseResources() {
    let actions = cleanups.values
    cleanups.removeAll()
    for action in actions { action() }
    menu = nil
  }
  func close() {
    guard let scene else { return }
    UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { _ in
      Task { @MainActor in AppModel.shared.showToast(AppToast(text: "无法关闭媒体窗口，请重试")) }
    }
  }
}

extension EnvironmentValues {
  @Entry var macMediaWindow: MacMediaWindowContext? = nil
}

@MainActor
final class MacMediaSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private let context = MacMediaWindowContext()
  private let model = MacMediaWindowModel()

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    MacWindowKind.mark(session, MacMediaWindows.configurationName)
    // 媒体是临时窗口，不持久化账号对象或临时签名 URL；重启后不恢复失效的媒体场景。
    guard let content = MacMediaWindows.shared.take(options.userActivities) else {
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
      if !UIApplication.shared.openSessions.contains(where: { $0.configuration.name == "Main" }) {
        // 用户可能先关闭聊天再退出 App；只剩失效媒体会话时仍须恢复可用的主窗口。
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication))
      }
      return
    }
    scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(value: false)
    scene.sizeRestrictions?.minimumSize = CGSize(width: 400, height: 360)
    scene.sizeRestrictions?.allowsFullScreen = true
    scene.titlebar?.titleVisibility = .visible
    scene.title = content.title
    context.scene = scene
    let window = UIWindow(windowScene: scene)
    window.tintColor = .systemBlue
    model.content = content
    window.rootViewController = MacMediaWindowHost(rootView: MacMediaWindowRoot(model: model)
      .environment(AppModel.shared).environment(\.macMediaWindow, context), context: context)
    self.window = window
    window.makeKeyAndVisible()
    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 160, y: 120, width: 880, height: 660)))
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    invalidate()
  }

  var kind: MacMediaWindows.Content.Kind? { model.content?.kind }

  /// 换成另一张图 / 另一个视频：先停掉旧的（视频播放器等），再换内容和标题。
  func show(_ content: MacMediaWindows.Content) {
    context.releaseResources()
    model.content = content
    model.version += 1
    context.scene?.title = content.title
  }

  func invalidate() {
    context.releaseResources()
    window?.rootViewController = nil
    window = nil
  }
}

/// 将共享查看器限制在原生标题栏以下，避免 iOS 的 ignoresSafeArea 把深色背景铺到浅色标题下面。
final class MacMediaWindowHost<Content: View>: UIViewController {
  private let host: UIHostingController<Content>
  private let menuSource: MacMediaMenuSource
  init(rootView: Content, context: MacMediaWindowContext) {
    host = UIHostingController(rootView: rootView)
    menuSource = MacMediaMenuSource(context: context)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.view.clipsToBounds = true
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    host.didMove(toParent: self)
    view.addInteraction(UIContextMenuInteraction(delegate: menuSource))
  }
}

/// 媒体窗口根视图上的右键菜单（委托不能放在泛型类里：Objective-C 运行时找不到泛型类型里的委托方法）。
@MainActor
final class MacMediaMenuSource: NSObject, UIContextMenuInteractionDelegate {
  private weak var context: MacMediaWindowContext?
  init(context: MacMediaWindowContext) { self.context = context }

  func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                              configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
    guard let menu = context?.menu?() else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
  }
}

/// 媒体窗口正在显示的内容；换内容时 version 加一，整个查看器按新内容重建（翻页位置、播放器都从头来）。
@MainActor
@Observable
final class MacMediaWindowModel {
  var content: MacMediaWindows.Content?
  var version = 0
}

private struct MacMediaWindowRoot: View {
  let model: MacMediaWindowModel
  var body: some View {
    Group {
      switch model.content {
      case .message(let target, let session, let chatID):
        MediaViewer(target: target, session: session, chatId: chatID).environment(\.session, session)
      case .gallery(let gallery): URLGalleryView(gallery: gallery)
      case nil: Color.black
      }
    }
    .id(model.version)
  }
}

