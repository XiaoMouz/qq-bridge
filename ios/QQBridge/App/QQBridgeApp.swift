import SwiftUI

@main
struct QQBridgeApp: App {
  @UIApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var model = AppModel.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if AppDelegate.isRunningStateTests {
          // 测试真实 UI 状态模型，但不恢复账号、注册推送或读写用户的本地库。
          Color.clear
        } else {
        switch model.phase {
        case .launching:
          ProgressView()
        case .loggedOut:
          LoginView()
        case .ready(let session):
          RootView(session: session)
        }
        }
      }
      .environment(model)
      .task {
        guard !AppDelegate.isRunningStateTests else { return }
        delegate.attach(model)
        model.launch()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard !AppDelegate.isRunningStateTests else { return }
      model.setActive(phase == .active)
    }
  }
}
