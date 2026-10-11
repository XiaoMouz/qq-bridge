import SwiftUI

@main
struct QQBridgeApp: App {
  @UIApplicationDelegateAdaptor private var delegate: AppDelegate
  @State private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        switch model.phase {
        case .launching:
          ProgressView()
        case .loggedOut:
          LoginView()
        case .ready(let session):
          RootView(session: session)
        }
      }
      .environment(model)
      .task {
        delegate.attach(model)
        model.launch()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      model.setActive(phase == .active)
    }
  }
}
