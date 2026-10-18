import SwiftUI
import QQBridgeKit
import UIKit

/// 根视图：按登录阶段切换页面，并承载跨分区的全局浮层（连接状态、通话、横幅、提示、快速回复）。
struct MacRootView: View {
  let router: MacCommandRouter
  @Environment(AppModel.self) private var model
  @State private var manualSync = MacManualSync()

  var body: some View {
    Group {
      switch model.phase {
      case .launching: ProgressView("正在打开 BetterChat…")
      case .loggedOut: MacLoginPage()
      case .ready(let session):
        MacWorkspace(session: session, manualSync: manualSync, router: router)
          .environment(\.session, session)
          .modifier(MacGlobalOverlays(session: session, manualSync: manualSync, router: router))
          .environment(\.macFullScreenCoverDidDismiss, { [weak router] in router?.workspace?.presentationDidDismiss() })
      }
    }
    .onChange(of: model.session == nil) { _, loggedOut in
      if loggedOut { MacMediaWindows.shared.closeAll() }
    }
  }
}

/// 全局浮层单独成修饰器，避免根视图修饰链过长导致类型推断超时（见 lessons 观察中）。
private struct MacGlobalOverlays: ViewModifier {
  let session: Session
  let manualSync: MacManualSync
  let router: MacCommandRouter
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    content
      // 状态条（同步、连接、掉线、通话）和新消息横幅都浮在右上角，不参与布局：
      // 以前放在顶部安全区里，每出现 / 消失一次整个窗口内容都被推上推下（2026-10-16 用户反馈）。
      // 放右上角而不是正中：窄窗口时不盖住左上的搜索框（2026-10-14 的问题）。
      .overlay(alignment: .topTrailing) { floatingStatus }
      .animation(.spring(duration: 0.35), value: model.banner)
      .animation(.spring(duration: 0.35), value: hasStatus)
      .overlay(alignment: .bottom) { toast }
      .alert("同步未完成", isPresented: Binding(get: { manualSync.error != nil }, set: { if !$0 { manualSync.error = nil } })) {
        Button("好", role: .cancel) { manualSync.error = nil }
      } message: {
        Text(manualSync.error ?? "")
      }
      .modifier(MacQuickReplyOpener())
      .sheet(isPresented: Binding(get: {
        model.calls.call != nil && !model.calls.minimized && (model.calls.expanded || !model.calls.isRinging || !model.calls.quiet)
      }, set: { if !$0 { model.calls.minimized = true } })) {
        CallScreen(manager: model.calls, session: session)
          .frame(minWidth: 360, minHeight: 440)
      }
  }

  private var showsCallBanner: Bool {
    model.calls.call != nil && !model.calls.ended
      && !(model.calls.quiet && model.calls.isRinging && !model.calls.expanded)
  }

  private var hasStatus: Bool {
    manualSync.isRunning || model.connection != .online || model.qqOnline == false
      || showsCallBanner
  }

  private var floatingStatus: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if hasStatus { statusStack }
      messageBanner
    }
    .frame(width: MacMetrics.messageBannerWidth, alignment: .trailing)
    .padding(.top, 8)
    .padding(.trailing, 6)
  }

  private var statusStack: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if manualSync.isRunning {
        MacStatusPill { ProgressView().controlSize(.small); Text("正在同步会话…") }
      }
      if model.connection != .online {
        ConnectionBanner(state: model.connection).padding(8).glassEffect()
      } else if model.qqOnline == false {
        Button("QQ 已掉线 · 扫码登录", systemImage: "qrcode") { MacQqLoginWindow.open() }
          .buttonStyle(.plain)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .glassEffect(.regular.interactive(), in: .capsule)
      }
      if showsCallBanner {
        CallBanner(manager: model.calls, session: session)
      }
    }
    .transition(.move(edge: .trailing).combined(with: .opacity))
  }

  /// 通话横幅在的时候不再叠一个消息横幅（和以前一样）。
  @ViewBuilder private var messageBanner: some View {
    if !showsCallBanner, let banner = model.banner {
      InAppBannerView(banner: banner) {
        model.banner = nil
        model.quickReplyChat = banner.chatId
      } onDismiss: { model.banner = nil }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  @ViewBuilder private var toast: some View {
    if let toast = model.toast {
      AppToastView(toast: toast) {
        model.dismissToast()
        model.quickReplyChat = nil
        model.pendingChat = toast.chatId
      }.frame(maxWidth: MacMetrics.statusMaxWidth).padding(.bottom, 100)
    }
  }
}

/// 快速回复：AppModel.quickReplyChat 被设上（横幅、会话列表右键）就开一个独立的小窗口（见 MacQuickReplyWindow），然后清掉请求。
private struct MacQuickReplyOpener: ViewModifier {
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    content.onChange(of: model.quickReplyChat) { _, id in
      guard let id else { return }
      model.quickReplyChat = nil
      MacQuickReplyWindow.open(id)
    }
  }
}
