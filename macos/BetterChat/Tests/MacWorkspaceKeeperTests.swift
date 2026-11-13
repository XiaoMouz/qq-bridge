import Foundation
import QQBridgeKit
import QQBridgeProto
import Testing
import UIKit
@testable import BetterChat

@MainActor
private final class FakeWorkspace: MacKeptWorkspace {
  var tornDown = 0
  func tearDown() { tornDown += 1 }
}

/// 代表右栏聊天页：带一个滚动视图，检查重开窗口后滚动位置还在。
@MainActor
private final class ScrollingPage: UIViewController {
  let scroll = UIScrollView()
  override func loadView() {
    scroll.contentSize = CGSize(width: 400, height: 5000)
    view = scroll
  }
}

/// ⌘W 关掉主窗口再重开（2026-11-12 用户反馈丢了消息位置、先闪占位页）：工作区不随窗口释放，新窗口接回同一个根控制器。
@Suite(.serialized)
@MainActor
struct MacWorkspaceKeeperTests {
  @Test func sameSessionReusesWorkspaceUntilLogout() {
    let keeper = MacWorkspaceKeeper<FakeWorkspace>()
    let session = NSObject()
    var made = 0
    let first = keeper.coordinator(for: session) { made += 1; return FakeWorkspace() }
    let reopened = keeper.coordinator(for: session) { made += 1; return FakeWorkspace() }
    #expect(first === reopened && made == 1 && first.tornDown == 0)

    // 换了账号（新的 Session）：旧工作区拆掉，再建新的。
    let other = keeper.coordinator(for: NSObject()) { made += 1; return FakeWorkspace() }
    #expect(other !== first && made == 2 && first.tornDown == 1)

    keeper.discard()
    #expect(other.tornDown == 1 && keeper.coordinator == nil)
  }

  @Test func reopenedWindowAdoptsKeptPageWithScrollPosition() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let page = ScrollingPage()

    var closed: UIWindow? = UIWindow(windowScene: scene)
    weak var firstHost: MacWorkspaceWindowHost?
    do {
      let host = MacWorkspaceWindowHost(content: page)
      firstHost = host
      closed?.rootViewController = host
      closed?.makeKeyAndVisible()
      host.view.layoutIfNeeded()
    }
    page.scroll.contentOffset = CGPoint(x: 0, y: 1234)
    #expect(page.view.window === closed)

    // 新窗口先建好、接回页面，旧窗口这时还没释放（实际的关窗顺序不保证）。
    let reopened = UIWindow(windowScene: scene)
    let secondHost = MacWorkspaceWindowHost(content: page)
    reopened.rootViewController = secondHost
    reopened.makeKeyAndVisible()
    secondHost.view.layoutIfNeeded()
    #expect(page.parent === secondHost)
    #expect(page.view.window === reopened)
    #expect(firstHost?.children.isEmpty ?? true)

    // 旧窗口这时才释放：页面不能被它带走。
    closed?.isHidden = true
    closed?.rootViewController = nil
    closed = nil
    #expect(page.parent === secondHost && page.view.window === reopened)
    #expect(page.scroll.contentOffset.y == 1234)

    reopened.isHidden = true
    reopened.rootViewController = nil
  }
}

/// 2026-11-13 用户反馈：侧栏搜索后焦点还在搜索框时 ⌘W，再从 Dock 打开，左栏整个空了且救不回来。
/// 用真实的场景销毁（借设置窗口的场景当主窗口，requestSceneSessionDestruction 等同 ⌘W）和真实工作区复现：
/// 修之前场景已销毁、搜索框仍是第一响应者。
@Suite(.serialized)
@MainActor
struct MacWorkspaceReopenSearchTests {
  private func pump(_ n: Int = 30) async {
    for _ in 0..<n { try? await Task.sleep(for: .milliseconds(20)) }
  }

  private func waitFor(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
  }

  private func settingsScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes.first {
      $0.delegate is MacSettingsSceneDelegate && $0.activationState != .unattached
    } as? UIWindowScene
  }

  private func searchField(in view: UIView) -> UISearchTextField? {
    if let field = view as? UISearchTextField { return field }
    for sub in view.subviews { if let field = searchField(in: sub) { return field } }
    return nil
  }

  /// 打开一个新场景并把工作区接进它的窗口。
  private func openWindow(with coordinator: MacWorkspaceCoordinator) async throws -> UIWindow {
    MacSettingsWindow.open()
    await waitFor { settingsScene() != nil }
    let scene = try #require(settingsScene())
    let window = try #require((scene.delegate as? MacSettingsSceneDelegate)?.window)
    window.rootViewController = MacWorkspaceWindowHost(content: coordinator.rootViewController)
    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 100, y: 100, width: 1100, height: 700)))
    await pump()
    return window
  }

  @Test func closingWhileSearchFieldFocusedKeepsListRecoverable() async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("reopen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let session = try Session(config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:9")!), token: "test", container: container)
    for i in 1...4 {
      var dialog = Qqbridge_V1_Dialog()
      dialog.chatID = Int64(i)
      dialog.peerID = Int64(1000 + i)
      dialog.scene = .group
      dialog.topTime = Int64(1_800_000_000 + i)
      try session.store.apply(dialog: dialog, pts: Int64(i))
    }
    let coordinator = MacWorkspaceAssembly.makeCoordinator(session: session, model: AppModel.shared,
                                                           manualSync: MacManualSync(), router: MacCommandRouter())
    defer { coordinator.tearDown() }

    let first = try await openWindow(with: coordinator)
    let field = try #require(searchField(in: first))
    field.becomeFirstResponder()
    field.text = "测试"
    field.sendActions(for: .editingChanged)
    await pump()
    #expect(field.isFirstResponder && coordinator.sidebar.isFiltering)

    // ⌘W：场景销毁后搜索框不能还占着第一响应者（它的窗口已经没了，之后键盘输入到不了它）。
    MacSettingsWindow.close()
    await waitFor { settingsScene() == nil }
    await pump()
    #expect(!field.isFirstResponder)

    let reopened = try await openWindow(with: coordinator)
    let again = try #require(searchField(in: reopened))
    #expect(again.window === reopened)
    #expect(again.text == coordinator.sidebar.query)

    // 清掉搜索词，会话列表回来。
    again.text = ""
    again.sendActions(for: .editingChanged)
    await pump()
    #expect(!coordinator.sidebar.isFiltering)
    let list = try #require(coordinator.dialogs.viewIfLoaded)
    #expect(list.window === reopened)
    var layer: UIView? = list
    var opaque = true
    while let view = layer, view !== reopened {
      if view.isHidden || view.alpha < 0.01 { opaque = false }
      layer = view.superview
    }
    #expect(opaque)
    #expect(coordinator.dialogs.collectionView.numberOfItems(inSection: 0) == 4)

    MacSettingsWindow.close()
    await waitFor { settingsScene() == nil }
  }
}
