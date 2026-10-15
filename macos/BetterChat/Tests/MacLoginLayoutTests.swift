import Foundation
import Testing
import UIKit
@testable import BetterChat
@testable import QQBridgeKit

@MainActor private struct LoginLayoutPreferences: MacLoginPreferences {
  var server = "https://example.invalid"
  var username = "布局验收"
  func save(server: String, username: String) {}
}
private struct LoginLayoutError: LocalizedError {
  var errorDescription: String? {
    "无法连接服务器。请确认服务器地址、网络连接和账号配置后重试。此处使用较长错误文字检查最小窗口下的换行、滚动及登录按钮可达性。"
  }
}
@MainActor private struct LoginLayoutAuthentication: MacAuthenticationService {
  func signIn(server: String, username: String, password: String) async throws { throw LoginLayoutError() }
}
/// 不联网：地址按最小规则补全，健康请求立即以长错误失败。
@MainActor private struct LoginLayoutReachability: MacServerReachabilityService {
  func resolve(_ input: String) -> URL? { URL(string: input.contains("://") ? input : "https://" + input) }
  func healthStatus(of server: URL) async throws -> Int? { throw LoginLayoutError() }
}
private let layoutPresets = [
  MacServerPreset(title: "本机", address: "127.0.0.1:8080"),
  MacServerPreset(title: "远端", address: "example.invalid"),
]

@Suite(.serialized) @MainActor
struct MacLoginLayoutTests {
  @Test func healthUpdatesDoNotEraseTypedPassword() async throws {
    let model = makeModel()
    let controller = MacLoginController(viewModel: model)
    controller.loadViewIfNeeded()
    let field = try #require(descendants(controller.view).compactMap { $0 as? UITextField }
      .first { $0.accessibilityLabel == "密码" })
    field.text = "仅本地检查"
    field.sendActions(for: .editingChanged)
    #expect(model.password == "仅本地检查")
    model.startHealthChecks()
    let deadline = ContinuousClock.now + .seconds(3)
    while model.health == .checking, ContinuousClock.now < deadline { await Task.yield() }
    // 让 Observation 派发的页面刷新落到实际控件上。
    await Task.yield()
    #expect(field.text == "仅本地检查")
    model.cancel()
    while field.text?.isEmpty == false, ContinuousClock.now < deadline { await Task.yield() }
    #expect(field.text?.isEmpty != false)
  }

  @Test func loginErrorsPreserveServerMeaning() {
    #expect(MacWorkspaceAssembly.loginErrorMessage(APIError(code: .unauthenticated, message: "unauthenticated")) == "用户名或密码不对")
    #expect(MacWorkspaceAssembly.loginErrorMessage(APIError(code: .permissionDenied, message: "账号已停用")) == "登录失败：账号已停用")
    #expect(MacWorkspaceAssembly.loginErrorMessage(LoginLayoutError()).contains("无法连接服务器"))
  }

  @Test func longErrorAndFormRemainReachableInMinimumWindow() async throws {
    let model = makeModel()
    model.password = "仅本地布局占位"
    model.submit()
    let deadline = ContinuousClock.now + .seconds(3)
    while model.isSubmitting, ContinuousClock.now < deadline { await Task.yield() }
    #expect(model.error != nil)
    let controller = MacLoginController(viewModel: model)
    check(controller, size: CGSize(width: 440, height: 428))
  }

  @Test func longServerAddressAndHealthErrorRemainReachable() async throws {
    let model = makeModel()
    let host = String(repeating: "very-long-subdomain-segment-", count: 8) + "example.invalid"
    model.updateServer(host + ":8080/bridge/prefix")
    model.startHealthChecks()
    let deadline = ContinuousClock.now + .seconds(3)
    while model.health == .checking, ContinuousClock.now < deadline { await Task.yield() }
    #expect(model.health == .failed(LoginLayoutError().localizedDescription))
    #expect(model.canRetryHealthCheck)
    model.password = "仅本地布局占位"
    model.submit()
    while model.isSubmitting, ContinuousClock.now < deadline { await Task.yield() }
    #expect(model.error != nil)
    let controller = MacLoginController(viewModel: model)
    for size in [CGSize(width: 440, height: 428), CGSize(width: 1024, height: 588)] {
      check(controller, size: size)
    }
    let labels = descendants(controller.view).compactMap { $0 as? UILabel }
    let resolved = try #require(labels.first { $0.accessibilityLabel == "实际连接" })
    #expect(resolved.text == model.resolvedServerText)
    #expect(resolved.bounds.height > resolved.font.lineHeight * 1.5, "长地址应换行而不是截断")
    let health = try #require(labels.first { $0.accessibilityLabel == "服务器连通性" })
    #expect(health.text == model.healthText && !health.isHidden)
    let buttons = descendants(controller.view).compactMap { $0 as? UIButton }
    #expect(buttons.contains { $0.accessibilityLabel == "服务器预设" && $0.menu != nil && $0.showsMenuAsPrimaryAction })
    #expect(buttons.contains { $0.accessibilityLabel == "重新检查服务器连通性" && !$0.isHidden })
    model.stopHealthChecks()
  }

  @Test func formRemainsReachableAcrossWideAndCompactResize() {
    let model = makeModel()
    let controller = MacLoginController(viewModel: model)
    for size in [CGSize(width: 1024, height: 588), CGSize(width: 440, height: 428), CGSize(width: 600, height: 588)] {
      check(controller, size: size)
    }
  }

  private func makeModel() -> MacLoginViewModel {
    MacLoginViewModel(
      authentication: LoginLayoutAuthentication(), preferences: LoginLayoutPreferences(),
      reachability: LoginLayoutReachability(), presets: layoutPresets)
  }

  /// 宽屏时表单不超过 360 并水平居中。
  private func checkFormWidth(_ root: UIView, size: CGSize) {
    guard let field = descendants(root).first(where: { $0.accessibilityLabel == "用户名" }) else { return }
    let rect = field.convert(field.bounds, to: root)
    #expect(rect.width <= 360.5)
    if size.width >= 360 + 48 { #expect(abs(rect.midX - size.width / 2) <= 1) }
  }

  private func check(_ controller: MacLoginController, size: CGSize) {
    let root = controller.view!
    root.frame = CGRect(origin: .zero, size: size)
    root.setNeedsLayout()
    root.layoutIfNeeded()
    checkFormWidth(root, size: size)
    let all = descendants(root)
    // 隐藏的控件不参与布局，不计入可达性检查。
    let controls = all.filter { view in
      guard !isHidden(view, in: root) else { return false }
      return view is UITextField || view is UIButton || (view as? UILabel)?.text?.isEmpty == false
    }
    #expect(controls.count >= 6)
    for control in controls {
      let rect = control.convert(control.bounds, to: root)
      #expect(rect.minX >= -0.5 && rect.maxX <= size.width + 0.5)
      if rect.minY < -0.5 || rect.maxY > size.height + 0.5 {
        let scroll = ancestorScroll(control)
        #expect(scroll != nil, "超出可见高度的控件必须可以滚动到达：\(control.accessibilityLabel ?? String(describing: type(of: control)))")
        if let scroll {
          let inScroll = control.convert(control.bounds, to: scroll)
          #expect(inScroll.minY >= -0.5 && inScroll.maxY <= scroll.contentSize.height + 0.5)
          #expect(scroll.contentSize.height > scroll.bounds.height)
        }
      }
      if let label = control as? UILabel {
        let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
        #expect(label.bounds.height >= needed - 0.5, "文字不能靠压缩高度而隐藏")
      }
      if control is UITextField { #expect(control.bounds.height >= 35.5) }
    }
  }

  private func descendants(_ root: UIView) -> [UIView] { root.subviews.flatMap { [$0] + descendants($0) } }
  private func isHidden(_ view: UIView, in root: UIView) -> Bool {
    var current: UIView? = view
    while let node = current, node !== root {
      if node.isHidden { return true }
      current = node.superview
    }
    return false
  }
  private func ancestorScroll(_ view: UIView) -> UIScrollView? {
    var current = view.superview
    while let parent = current {
      if let scroll = parent as? UIScrollView { return scroll }
      current = parent.superview
    }
    return nil
  }
}
