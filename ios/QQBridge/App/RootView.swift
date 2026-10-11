import QQBridgeKit
import SwiftUI

struct RootView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var showQqLogin = false
  @State private var tab = 0

  var body: some View {
    TabView(selection: Binding(get: { tab }, set: { new in
      // 已经在"消息"页时再点一次：跳到下一个有未读的会话。
      if new == 0, tab == 0 { model.nextUnreadTick += 1 }
      tab = new
    })) {
      Tab("消息", systemImage: "bubble.left.and.bubble.right", value: 0) {
        DialogListView(session: session)
      }
      .badge(model.unreadBadge)
      Tab("联系人", systemImage: "person.2", value: 1) {
        ContactsView(session: session)
      }
      Tab("设置", systemImage: "gearshape", value: 2) {
        SettingsView(session: session)
      }
      Tab(value: 3, role: .search) {
        SearchView(session: session)
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .statusAccessory(isEnabled: model.connection != .online || model.qqOnline == false) {
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
    // 点了通知：切到消息页，由会话列表打开对应会话。
    .onChange(of: model.pendingChat) { _, chatId in if chatId != nil { tab = 0 } }
    .sheet(isPresented: $showQqLogin) { QqLoginSheet(session: session) }
    .environment(\.session, session)
  }
}

extension View {
  /// 标签栏上方的状态条。iOS 26.1 起用系统的 tabViewBottomAccessory（能按需显示 / 隐藏）；
  /// 26.0 没有 isEnabled 参数，改成浮在标签栏上方的玻璃胶囊。
  @ViewBuilder func statusAccessory(isEnabled: Bool, @ViewBuilder content: () -> some View) -> some View {
    if #available(iOS 26.1, *) {
      tabViewBottomAccessory(isEnabled: isEnabled, content: content)
    } else {
      let banner = content()
      overlay(alignment: .bottom) {
        if isEnabled {
          banner
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .padding(.bottom, 72)
        }
      }
    }
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
