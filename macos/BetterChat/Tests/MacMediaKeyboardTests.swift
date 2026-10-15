import Testing
import UIKit
@testable import BetterChat

@Suite(.serialized) @MainActor
struct MacMediaKeyboardTests {
  @Test func presentedFormBlocksCachedMediaCommandsAndDismissalRestoresThem() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    var calls: [String] = []
    let keyboard = MacMediaKeyboard.Controller(actions: MacMediaKeyboard(
      close: { calls.append("close") }, previous: { calls.append("previous") },
      next: { calls.append("next") }, togglePlayback: { calls.append("playback") }))
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.addChild(keyboard)
    keyboard.view.frame = root.view.bounds
    root.view.addSubview(keyboard.view)
    keyboard.didMove(toParent: root)
    defer {
      root.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
    }
    let commands = try #require(keyboard.keyCommands)
    #expect(commands.count == 4)
    let sheet = UIViewController()
    sheet.modalPresentationStyle = .formSheet
    root.present(sheet, animated: false)
    await wait { root.presentedViewController === sheet && sheet.view.window != nil && !sheet.isBeingPresented }
    // 用真实祖先呈现关系检查媒体响应者；已排入响应链的旧命令也不能穿透新弹层。
    #expect(keyboard.keyCommands?.isEmpty == true)
    for command in commands { keyboard.perform(command.action, with: command) }
    #expect(calls.isEmpty)
    root.dismiss(animated: false)
    await wait { root.presentedViewController == nil }
    for command in try #require(keyboard.keyCommands) { keyboard.perform(command.action, with: command) }
    #expect(calls == ["close", "previous", "next", "playback"])
  }

  private func wait(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }
}
