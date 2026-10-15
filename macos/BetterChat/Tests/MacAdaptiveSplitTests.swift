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
    controller.hasDetail = { true }
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

@Suite(.serialized)
@MainActor
struct MacAdaptiveSplitTests {
  @Test func transparentCoverDefersCompactLayoutUntilDismissed() async throws {
    let fixture = try AdaptiveSplitFixture(width: 1024)
    defer { fixture.dispose() }
    let cover = await fixture.present(.overFullScreen)
    #expect(cover.view.window === fixture.controller.view.window)
    fixture.resize(440)
    #expect(!fixture.controller.isCompact)
    await fixture.dismiss()
    #expect(fixture.controller.isCompact)
    #expect(fixture.controller.isShowingCompactDetail)
  }

  @Test func transparentCoverDefersWideLayoutUntilDismissed() async throws {
    let fixture = try AdaptiveSplitFixture(width: 440)
    defer { fixture.dispose() }
    #expect(fixture.controller.isCompact)
    _ = await fixture.present(.overFullScreen)
    fixture.resize(1024)
    #expect(fixture.controller.isCompact)
    await fixture.dismiss()
    #expect(!fixture.controller.isCompact)
  }

  @Test func formSheetDoesNotSuspendWindowAdaptation() async throws {
    let fixture = try AdaptiveSplitFixture(width: 1024)
    defer { fixture.dispose() }
    _ = await fixture.present(.formSheet)
    fixture.resize(440)
    #expect(fixture.controller.isCompact)
    fixture.resize(1024)
    #expect(!fixture.controller.isCompact)
    await fixture.dismiss()
  }
}
