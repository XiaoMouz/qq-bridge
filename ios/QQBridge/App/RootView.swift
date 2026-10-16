import QQBridgeKit
import SwiftUI

struct RootView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var showQqLogin = false
  @State private var tab = 0

  /// 通话全屏：来电时只在消息页（没开着会话）或点了横幅时；接听后除非收起。
  private var showFullCall: Bool {
    let calls = model.calls
    guard calls.call != nil, !calls.minimized else { return false }
    if calls.isRinging, !calls.expanded {
      // 免打扰的群发起的群语音：不弹出（在会话列表、群聊里点「加入」）。
      if calls.quiet { return false }
      return tab == 0 && model.openChatId == nil
    }
    return true
  }

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
      // 有新版本：一个「新」字，不是数字（免得和未读混淆）；进过一次「关于」就消失。
      .badge(AppUpdate.shared.showsBadge ? Text("新") : nil)
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
    // App 内横幅：别的会话来消息（前台不发系统通知）。
    .overlay(alignment: .top) {
      if let banner = model.banner {
        InAppBannerView(banner: banner) {
          model.banner = nil
          model.quickReplyChat = banner.chatId
        } onDismiss: {
          model.banner = nil
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.35), value: model.banner)
    // 底部提示：转发成功等，点"查看"打开目标会话。
    .overlay(alignment: .bottom) {
      if let toast = model.toast {
        AppToastView(toast: toast) {
          model.dismissToast()
          model.quickReplyChat = nil
          model.pendingChat = toast.chatId
        }
        .padding(.bottom, 90)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.35), value: model.toast)
    .sheet(item: Binding(get: { model.quickReplyChat.map(ChatRef.init) }, set: { model.quickReplyChat = $0?.id })) { ref in
      NavigationStack {
        ChatScreen(session: session, chatId: ref.id, onExpand: {
          model.quickReplyChat = nil
          // 等浮层收起再跳（收起动画中改导航会被忽略）。
          Task {
            try? await Task.sleep(for: .milliseconds(400))
            model.pendingChat = ref.id
          }
        })
      }
      .presentationDetents([.medium, .large])
    }
    // 来电：在消息页（没开着会话）时全屏，其他地方只在顶部显示横幅；接听后全屏通话界面，可以收起成顶部小条。
    .fullScreenCover(isPresented: Binding(get: { showFullCall }, set: { _ in })) {
      CallScreen(manager: model.calls, session: session)
    }
    .overlay(alignment: .top) {
      if model.calls.call != nil, !showFullCall, !model.calls.ended, !(model.calls.quiet && model.calls.isRinging && !model.calls.expanded) {
        CallBanner(manager: model.calls, session: session)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.35), value: showFullCall)
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

struct ChatRef: Identifiable {
  let id: Int64
}
