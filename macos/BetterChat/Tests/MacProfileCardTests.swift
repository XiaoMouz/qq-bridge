import SwiftUI
import UIKit
import Testing
@testable import BetterChat

@MainActor
private final class ProfileCardFixture<ID: Hashable> {
  let window: UIWindow
  let root = UIViewController()
  let anchor = MacFormAnchor<ID>()
  var selection: ID?
  var closeCount = 0

  init() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    window = UIWindow(windowScene: scene)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    root.addChild(anchor)
    anchor.view.frame = root.view.bounds
    root.view.addSubview(anchor.view)
    anchor.didMove(toParent: root)
  }

  func select(_ id: ID?) {
    selection = id
    anchor.update(id: id, content: id.map { AnyView(Text("测试表单 \(String(describing: $0))")) }) { [weak self] in
      guard let self else { return }
      closeCount += 1
      select(nil)
    }
  }

  func presentSheet(containingAnchor: Bool) async -> UIViewController {
    let sheet = UIHostingController(rootView: Text("快速回复测试"))
    sheet.modalPresentationStyle = .formSheet
    sheet.preferredContentSize = CGSize(width: 540, height: 440)
    root.present(sheet, animated: true)
    await waitUntil { self.root.presentedViewController === sheet && !sheet.isBeingPresented && sheet.view.window != nil }
    if containingAnchor {
      anchor.willMove(toParent: nil)
      anchor.view.removeFromSuperview()
      anchor.removeFromParent()
      sheet.addChild(anchor)
      anchor.view.frame = sheet.view.bounds
      sheet.view.addSubview(anchor.view)
      anchor.didMove(toParent: sheet)
    }
    return sheet
  }

  func dispose() {
    anchor.tearDown()
    root.dismiss(animated: false)
    anchor.willMove(toParent: nil)
    anchor.view.removeFromSuperview()
    anchor.removeFromParent()
    window.isHidden = true
    window.rootViewController = nil
  }

  // 等实际 UIKit 转场结束；限制总时长，不把 sleep 当作呈现成功的证据。
  func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "资料卡转场未在期限内达到预期状态")
  }
  func waitForCard() async -> UIViewController? {
    await waitUntil {
      self.root.presentedViewController != nil && self.root.presentedViewController?.isBeingPresented == false
    }
    return root.presentedViewController
  }
}

@Suite(.serialized)
@MainActor
struct MacProfileCardTests {
  @Test func storageHashSelectionClosesReopensAndHandlesEscape() async throws {
    let fixture = try ProfileCardFixture<String>()
    defer { fixture.dispose() }
    fixture.select("storage-sha")
    let first = try #require(await fixture.waitForCard())
    fixture.select(nil)
    await fixture.waitUntil { first.presentingViewController == nil && fixture.root.presentedViewController == nil }
    fixture.select("storage-sha")
    let second = try #require(await fixture.waitForCard())
    #expect(first !== second)
    let escape = try #require(second.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
    let action = try #require(escape.action)
    #expect(UIApplication.shared.sendAction(action, to: second, from: escape, for: nil))
    await fixture.waitUntil { fixture.selection == nil && fixture.root.presentedViewController == nil }
    #expect(fixture.closeCount == 1)
  }

  @Test func clearingSelectionBeforeScheduledPresentationDoesNotOpenCard() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    fixture.select(1)
    fixture.select(nil)
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.root.presentedViewController == nil && fixture.closeCount == 0)
  }

  @Test func ownerClearingSelectionAllowsReopeningSameCard() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    fixture.select(1)
    let first = try #require(await fixture.waitForCard())
    fixture.select(nil)
    await fixture.waitUntil { fixture.root.presentedViewController == nil && first.presentingViewController == nil }
    #expect(fixture.selection == nil)
    fixture.select(1)
    let second = try #require(await fixture.waitForCard())
    #expect(first !== second && fixture.selection == 1)
  }

  @Test func externalDismissClearsOwnerAndAllowsReopening() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    fixture.select(2)
    let card = try #require(await fixture.waitForCard())
    // 协调器位于窗口根控制器下面；验证子控制器能识别并关闭祖先呈现的资料卡。
    #expect(fixture.anchor.presentedViewController === card)
    await withCheckedContinuation { continuation in
      fixture.anchor.dismiss(animated: false) { continuation.resume() }
    }
    await fixture.waitUntil { fixture.selection == nil }
    #expect(fixture.closeCount == 1)
    fixture.select(2)
    _ = try #require(await fixture.waitForCard())
    #expect(fixture.selection == 2)
  }

  @Test func replacingSelectionDismissesOldCardBeforePresentingNewOne() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    fixture.select(3)
    let first = try #require(await fixture.waitForCard())
    fixture.select(4)
    await fixture.waitUntil {
      fixture.root.presentedViewController != nil && fixture.root.presentedViewController !== first
        && fixture.root.presentedViewController?.isBeingPresented == false
    }
    #expect(fixture.selection == 4 && fixture.closeCount == 0)
  }

  @Test func teardownDuringReplacementNeverPresentsAgain() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    fixture.select(5)
    let first = try #require(await fixture.waitForCard())
    fixture.select(6)
    await fixture.waitUntil { first.isBeingDismissed || first.presentingViewController == nil }
    fixture.anchor.tearDown()
    await fixture.waitUntil { first.presentingViewController == nil }
    // 模拟 SwiftUI 移除过程中，旧宿主仍短暂留在窗口；转场 completion 不得重新打开。
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.root.presentedViewController == nil)
    #expect(fixture.closeCount == 0)
  }

  @Test func profileInsideQuickReplyPresentsAboveItsOwningSheet() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    let sheet = await fixture.presentSheet(containingAnchor: true)
    fixture.select(7)
    await fixture.waitUntil { sheet.presentedViewController != nil && sheet.presentedViewController?.isBeingPresented == false }
    let first = try #require(sheet.presentedViewController)
    #expect(fixture.root.presentedViewController === sheet)
    fixture.select(nil)
    await fixture.waitUntil { sheet.presentedViewController == nil && first.presentingViewController == nil }
    #expect(fixture.root.presentedViewController === sheet)
    fixture.select(7)
    await fixture.waitUntil { sheet.presentedViewController != nil && sheet.presentedViewController?.isBeingPresented == false }
    #expect(sheet.presentedViewController !== first)
  }

  @Test func unrelatedSheetDoesNotReceiveUnderlyingPageProfile() async throws {
    let fixture = try ProfileCardFixture<Int64>()
    defer { fixture.dispose() }
    let sheet = await fixture.presentSheet(containingAnchor: false)
    fixture.select(8)
    for _ in 0..<20 { await Task.yield() }
    #expect(sheet.presentedViewController == nil)
    #expect(fixture.root.presentedViewController === sheet)
  }
}
