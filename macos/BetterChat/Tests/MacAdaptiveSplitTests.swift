import SwiftUI
import UIKit
import Testing
@testable import BetterChat

@MainActor
private final class AdaptiveSplitFixture {
  let window: UIWindow
  let host = UIViewController()
  let controller = MacAdaptiveSplitController(sidebarRoot: UIViewController(), detailRoot: UIViewController())

  init(width: CGFloat) throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.loadViewIfNeeded()
    host.addChild(controller)
    controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 640)
    host.view.addSubview(controller.view)
    controller.didMove(toParent: host)
    controller.view.layoutIfNeeded()
  }

  func resize(_ width: CGFloat) {
    controller.view.frame.size.width = width
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
  }

  func present(_ style: UIModalPresentationStyle) async -> UIViewController {
    let cover = UIHostingController(rootView: Text("导航覆盖测试"))
    cover.modalPresentationStyle = style
    cover.preferredContentSize = CGSize(width: 400, height: 440)
    host.present(cover, animated: true)
    await waitUntil { cover.viewIfLoaded?.window != nil && !cover.isBeingPresented }
    return cover
  }

  func dismiss() async {
    host.dismiss(animated: false)
    await waitUntil { self.host.presentedViewController == nil }
    controller.presentationDidDismiss()
    controller.view.layoutIfNeeded()
  }

  func dispose() {
    host.dismiss(animated: false)
    window.isHidden = true
    window.rootViewController = nil
  }

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "实际 UIKit 转场未在期限内完成")
  }
}

// 2026-10-17（81e2017）起窄窗口不再切单栏导航，只收起侧栏、隐藏检查器；测试按现在的行为改写（2026-11-08）。
@Suite(.serialized)
@MainActor
struct MacAdaptiveSplitTests {
  @Test func narrowWindowCollapsesAndWideWindowRestores() async throws {
    let fixture = try AdaptiveSplitFixture(width: 1024)
    defer { fixture.dispose() }
    #expect(!fixture.controller.isNarrow)
    fixture.resize(440)
    #expect(fixture.controller.isNarrow)
    fixture.resize(1024)
    #expect(!fixture.controller.isNarrow)
  }

  @Test func inspectorWaitsWhileNarrowAndReturnsWhenWide() async throws {
    let fixture = try AdaptiveSplitFixture(width: 440)
    defer { fixture.dispose() }
    let content = UIViewController()
    fixture.controller.showInspector(content)
    #expect(fixture.controller.isInspectorShown && fixture.controller.inspectorContent === content)
    fixture.resize(1024)
    #expect(fixture.controller.isInspectorShown)
    fixture.controller.showInspector(nil)
    #expect(!fixture.controller.isInspectorShown && fixture.controller.inspectorContent == nil)
  }

  @Test func coversDoNotBreakAdaptation() async throws {
    let fixture = try AdaptiveSplitFixture(width: 1024)
    defer { fixture.dispose() }
    let cover = await fixture.present(.overFullScreen)
    #expect(cover.view.window === fixture.controller.view.window)
    fixture.resize(440)
    await fixture.dismiss()
    #expect(fixture.controller.isNarrow)
    _ = await fixture.present(.formSheet)
    fixture.resize(1024)
    #expect(!fixture.controller.isNarrow)
    await fixture.dismiss()
  }

  /// 2026-11-09：收起是变成窄栏，不是藏起来；窄窗口自动窄栏，⌃⌘S 临时展开、打开详情后收回。
  @Test func collapseBecomesRailAndNarrowWindowExpandsTemporarily() async throws {
    UserDefaults.standard.removeObject(forKey: "mac.sidebarRail")
    defer { UserDefaults.standard.removeObject(forKey: "mac.sidebarRail") }
    let fixture = try AdaptiveSplitFixture(width: 1024)
    defer { fixture.dispose() }
    var changes: [Bool] = []
    fixture.controller.railChanged = { changes.append($0) }
    #expect(!fixture.controller.isRail)
    fixture.controller.toggleSidebar()
    #expect(fixture.controller.isRail && UserDefaults.standard.bool(forKey: "mac.sidebarRail"))
    fixture.controller.toggleSidebar()
    #expect(!fixture.controller.isRail)
    fixture.resize(700)
    #expect(fixture.controller.isRail)
    fixture.controller.toggleSidebar()
    #expect(!fixture.controller.isRail)
    fixture.controller.showDetail()
    #expect(fixture.controller.isRail)
    fixture.controller.expandSidebar()
    #expect(!fixture.controller.isRail)
    fixture.resize(1024)
    // 宽窗口回到用户自己的选择（完整侧栏），窄窗口里的临时展开不记住。
    #expect(!fixture.controller.isRail && !UserDefaults.standard.bool(forKey: "mac.sidebarRail"))
    #expect(changes == [true, false, true, false, true, false])
  }
}
