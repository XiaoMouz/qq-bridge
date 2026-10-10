import QQBridgeKit
import SwiftUI

struct RootView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var showQqLogin = false

  var body: some View {
    TabView {
      Tab("消息", systemImage: "bubble.left.and.bubble.right") {
        DialogListView(session: session)
      }
      Tab("联系人", systemImage: "person.2") {
        ContactsView(session: session)
      }
      Tab("设置", systemImage: "gearshape") {
        SettingsView(session: session)
      }
      Tab(role: .search) {
        SearchView(session: session)
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .tabViewBottomAccessory(isEnabled: model.connection != .online || model.qqOnline == false) {
      if model.connection != .online {
        ConnectionBanner(state: model.connection)
      } else {
        Button { showQqLogin = true } label: {
          Label("QQ 已掉线 · 点此扫码登录", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
        }
      }
    }
    .sheet(isPresented: $showQqLogin) { QqLoginSheet(session: session) }
    .environment(\.session, session)
  }
}

/// 不在线时显示在标签栏上方的状态条。
struct ConnectionBanner: View {
  let state: ConnectionState

  var body: some View {
    HStack(spacing: 8) {
      switch state {
      case .online:
        EmptyView()
      case .connecting:
        ProgressView().controlSize(.small)
        Text("正在同步…")
      case .offline(let retry, _):
        Image(systemName: "wifi.exclamationmark")
        Text("连不上服务器，\(Int(retry)) 秒后重试")
      case .unauthenticated:
        Image(systemName: "person.crop.circle.badge.exclamationmark")
        Text("需要重新登录")
      }
    }
    .font(.footnote)
    .padding(.horizontal)
  }
}

extension EnvironmentValues {
  @Entry var session: Session? = nil
}
