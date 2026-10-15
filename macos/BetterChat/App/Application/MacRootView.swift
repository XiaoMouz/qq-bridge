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
  @State private var qqLogin = false
  @State private var expandedQuickReply: (chatId: Int64, composer: Composer)?

  func body(content: Content) -> some View {
    content
      // 2026-10-14 离线实测：顶部 overlay 在 440 点窗口盖住搜索框；状态条必须参与安全区布局。
      .safeAreaInset(edge: .top, spacing: 0) {
        if hasStatus { statusStack.padding(.bottom, 8) }
      }
      .overlay(alignment: .bottom) { toast }
      .alert("同步未完成", isPresented: Binding(get: { manualSync.error != nil }, set: { if !$0 { manualSync.error = nil } })) {
        Button("好", role: .cancel) { manualSync.error = nil }
      } message: {
        Text(manualSync.error ?? "")
      }
      .sheet(isPresented: $qqLogin) { QqLoginSheet(session: session) }
      .modifier(MacQuickReplySheet(session: session, router: router, expanded: $expandedQuickReply))
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
      || showsCallBanner || model.banner != nil
  }

  private var statusStack: some View {
    VStack(spacing: 8) {
      if manualSync.isRunning {
        MacStatusPill { ProgressView().controlSize(.small); Text("正在同步会话…") }
      }
      if model.connection != .online {
        ConnectionBanner(state: model.connection).padding(8).glassEffect()
      } else if model.qqOnline == false {
        Button("QQ 已掉线 · 扫码登录", systemImage: "qrcode") { qqLogin = true }
          .buttonStyle(.plain)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .glassEffect(.regular.interactive(), in: .capsule)
      }
      if showsCallBanner {
        CallBanner(manager: model.calls, session: session)
      } else if let banner = model.banner {
        InAppBannerView(banner: banner) {
          model.banner = nil
          model.quickReplyChat = banner.chatId
        } onDismiss: { model.banner = nil }
      }
    }
    .padding(.top, 8).frame(maxWidth: MacMetrics.statusMaxWidth)
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

/// 快速回复浮层：草稿经命令路由与主会话交换；展开时等浮层实际消失再切换主会话，避免动画期间丢失导航。
private struct MacQuickReplySheet: ViewModifier {
  let session: Session
  let router: MacCommandRouter
  @Binding var expanded: (chatId: Int64, composer: Composer)?
  @Environment(AppModel.self) private var model

  func body(content: Content) -> some View {
    content.sheet(item: Binding(get: { model.quickReplyChat.map(ChatRef.init) }, set: { model.quickReplyChat = $0?.id }), onDismiss: {
      if let draft = expanded {
        expanded = nil
        router.workspace?.openChat(draft.chatId, composer: draft.composer)
      }
    }) { ref in
      MacQuickReplyPage(session: session, chatId: ref.id,
        initialComposer: router.workspace?.draftComposer(for: ref.id), onClose: { composer in
          router.workspace?.updateDraft(composer, for: ref.id)
        }) { composer in
        expanded = (ref.id, composer)
        model.quickReplyChat = nil
      }
      .environment(\.session, session)
      .frame(minWidth: 360, idealWidth: 680, minHeight: 440, idealHeight: 640)
    }
  }
}
