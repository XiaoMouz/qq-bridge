import SwiftUI

@main
struct QQBridgeApp: App {
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
      .task { model.launch() }
    }
    .onChange(of: scenePhase) { _, phase in
      model.setActive(phase == .active)
    }
  }
}
