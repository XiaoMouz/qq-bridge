// 「通知手机」：账号级设置（服务端存，经 pts 同步到本地库），这里是界面共用的状态和操作——
// 设置页、iOS 会话列表顶部的「通知未启用」、Mac 侧栏的按钮、点「手机通知已关闭」推送都走这一个。
// 状态只从本地库来（observeAccountSettings，本机或其他设备改了都经 Subscribe 落库），不轮询。
// Mac 的「本机在线时自动停用」是本机选项（UserDefaults），开着时每 30 秒 ReportPresence 续租，
// 服务端 75 秒收不到就当离线、恢复手机通知（睡眠、断网、崩溃都覆盖到，见 server push/phone-auto-mute.ts）。
import Foundation
import Observation
import QQBridgeKit
import QQBridgeProto
import UIKit
import UserNotifications

@MainActor
@Observable
final class PhoneNotifications {
  /// 手动开关（库里的值）。
  private(set) var manualOff = false
  /// 服务端算的：有设备在线、自动停用中。
  private(set) var autoOff = false
  /// 已发出、还没同步回来的手动值：期间不让旧的库值把开关拨回去。
  private(set) var pendingOff: Bool?
  /// 上一次改动失败（设置页提示）。
  private(set) var failed = false
  /// 本地库里的值读到过（没读到前不显示「通知未启用」，免得启动时闪一下）。
  private(set) var loaded = false
  /// 会话列表顶部的「通知未启用」点了忽略；通知恢复后清掉，下次再关时重新提示。
  private(set) var bannerIgnored = UserDefaults.standard.bool(forKey: PhoneNotifications.ignoredKey)

  /// 手动开关显示的值。
  var manualOn: Bool { !(pendingOff ?? manualOff) }
  /// 手机现在实际收不收新消息通知。
  var phoneOn: Bool { manualOn && !autoOff }
  var showsBanner: Bool { loaded && !phoneOn && !bannerIgnored }

  @ObservationIgnored private var session: Session?
  @ObservationIgnored private var observeTask: Task<Void, Never>?

  func attach(_ session: Session) {
    self.session = session
    observeTask?.cancel()
    observeTask = Task { [weak self] in
      do {
        for try await s in session.store.observeAccountSettings() {
          self?.update(s)
        }
      } catch {}
    }
    #if targetEnvironment(macCatalyst)
    restartPresence()
    #endif
  }

  /// 退出登录：停掉观察；Mac 先告诉服务端不再暂停手机通知（令牌马上要作废）。
  func detach() async {
    observeTask?.cancel()
    observeTask = nil
    #if targetEnvironment(macCatalyst)
    presenceTask?.cancel()
    presenceTask = nil
    if autoMuteHere { await report(mute: false) }
    #endif
    session = nil
    loaded = false
  }

  private func update(_ s: Qqbridge_V1_AccountSettings) {
    manualOff = s.phoneNotificationsOff
    autoOff = s.phoneAutoOff
    loaded = true
    if pendingOff == manualOff { pendingOff = nil }
    if phoneOn {
      if bannerIgnored {
        bannerIgnored = false
        UserDefaults.standard.set(false, forKey: Self.ignoredKey)
      }
      #if !targetEnvironment(macCatalyst)
      Self.removeOffNotice()
      #endif
    }
  }

  /// 手动开关。
  func setManual(on: Bool) {
    Task { _ = await send(off: !on, clearAuto: false) }
  }

  /// 「打开」（会话列表顶部、点推送）：手动开关打开，同时解除当前的在线自动停用。成功返回 true。
  func turnOn() async -> Bool {
    await send(off: false, clearAuto: true)
  }

  func ignoreBanner() {
    bannerIgnored = true
    UserDefaults.standard.set(true, forKey: Self.ignoredKey)
  }

  private func send(off: Bool, clearAuto: Bool) async -> Bool {
    guard let session else { return false }
    pendingOff = off
    failed = false
    var req = Qqbridge_V1_SetAccountSettingsRequest()
    req.settings.phoneNotificationsOff = off
    req.overrideAutoOff = clearAuto
    do {
      _ = try await session.api.auth.setAccountSettings(request: req, headers: session.api.headers).get()
      return true
    } catch {
      failed = true
      pendingOff = nil
      return false
    }
  }

  private static let ignoredKey = "phoneNotificationsBannerIgnored"

  /// 收掉「手机通知已关闭」那条推送（server notifier.notifyPhoneNotificationsOff，带 phoneNotifications = "off"）。
  nonisolated static func removeOffNotice() {
    let center = UNUserNotificationCenter.current()
    center.getDeliveredNotifications { list in
      let ids = list.filter { ($0.request.content.userInfo["phoneNotifications"] as? String) == "off" }.map(\.request.identifier)
      if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
  }

  // MARK: Mac：本机在线时自动停用

  #if targetEnvironment(macCatalyst)
  private(set) var autoMuteHere = UserDefaults.standard.bool(forKey: PhoneNotifications.autoMuteKey)
  @ObservationIgnored private var presenceTask: Task<Void, Never>?
  @ObservationIgnored private var terminateObserver: (any NSObjectProtocol)?

  func setAutoMuteHere(_ on: Bool) {
    guard on != autoMuteHere else { return }
    autoMuteHere = on
    UserDefaults.standard.set(on, forKey: Self.autoMuteKey)
    restartPresence()
    if !on { Task { await report(mute: false) } }
  }

  private func restartPresence() {
    presenceTask?.cancel()
    presenceTask = nil
    guard autoMuteHere, session != nil else { return }
    // 租约 75 秒、30 秒续一次：错过一次（网络抖动）也不会恢复手机通知。
    // Task.sleep 用的是连续时钟：睡眠醒来后马上续上，睡眠期间不续，服务端到期就恢复手机通知。
    presenceTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.report(mute: true)
        try? await Task.sleep(for: .seconds(30))
      }
    }
    if terminateObserver == nil {
      terminateObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.willTerminateNotification, object: nil, queue: .main
      ) { _ in
        // 退出时尽量马上恢复手机通知（来不及也没关系，租约 75 秒后到期）。
        MainActor.assumeIsolated { AppModel.shared.phoneNotifications.reportOfflineOnExit() }
      }
    }
  }

  private func reportOfflineOnExit() {
    guard autoMuteHere, let session else { return }
    var req = Qqbridge_V1_ReportPresenceRequest()
    req.mutePhone = false
    let done = DispatchSemaphore(value: 0)
    // 退出流程不等异步任务：在后台发出请求，最多等 1 秒。
    Task.detached {
      _ = await session.api.auth.reportPresence(request: req, headers: session.api.headers)
      done.signal()
    }
    _ = done.wait(timeout: .now() + 1)
  }

  private func report(mute: Bool) async {
    guard let session else { return }
    var req = Qqbridge_V1_ReportPresenceRequest()
    req.mutePhone = mute
    _ = await session.api.auth.reportPresence(request: req, headers: session.api.headers)
  }

  private static let autoMuteKey = "mac.autoMutePhoneWhileOnline"
  #endif
}
