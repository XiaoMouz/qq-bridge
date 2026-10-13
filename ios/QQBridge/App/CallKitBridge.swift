// 系统来电界面（CallKit）：App 不在前台时，服务端发 VoIP 推送（PushKit），这里交给 CallKit 显示系统来电（锁屏也能接）。
// - 收到 VoIP 推送必须马上报一个来电给 CallKit（系统规定，不报会被系统杀掉、以后不再投递）。
// - 接听 / 挂断 / 静音由系统界面发起，转给 CallManager；通话结束（对方挂断、别的设备接了）时告诉 CallKit。
// - 音频：CallKit 负责激活音频会话；LiveKit 关掉自动配置，等 CallKit 激活后再开引擎（LiveKit 推荐的 CallKit 用法）。
// App 在前台时服务端不发 VoIP 推送，来电由 App 内的界面显示（见 CallManager）。
import AVFoundation
import CallKit
import LiveKit
import PushKit
import QQBridgeProto
import UIKit

@MainActor
final class CallKitBridge: NSObject {
  static let shared = CallKitBridge()

  private let provider: CXProvider
  private let controller = CXCallController()
  private var registry: PKPushRegistry?
  /// 已经报给 CallKit 的通话：callId → CallKit 的 UUID。
  private var reported: [String: UUID] = [:]
  /// 报给 CallKit 后、App 还没拿到通话状态时，等它的轮询任务。
  private var poll: Task<Void, Never>?

  override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    // QQ 的通话不进系统「电话」的最近通话（点了也没法回拨）。
    config.includesCallsInRecents = false
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  /// 启动时调用：注册 VoIP 推送（拿到令牌后交给服务端）。
  func register() {
    guard registry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry
  }

  func isReported(_ callId: String) -> Bool { reported[callId] != nil }

  /// 通话结束（对方挂断、取消、别的设备接了）：收起系统来电界面。
  func reportEnded(_ callId: String, answeredElsewhere: Bool = false) {
    guard let uuid = reported.removeValue(forKey: callId) else { return }
    provider.reportCall(with: uuid, endedAt: Date(), reason: answeredElsewhere ? .answeredElsewhere : .remoteEnded)
    if reported.isEmpty { stopPolling() }
  }

  /// 在 App 里点了挂断：同步给 CallKit（系统界面也收起）。
  func requestEnd(_ callId: String) {
    guard let uuid = reported[callId] else { return }
    controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
  }

  /// App 里切静音：同步给 CallKit。
  func requestMute(_ callId: String, muted: Bool) {
    guard let uuid = reported[callId] else { return }
    controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { _ in }
  }

  private func callId(for uuid: UUID) -> String? {
    reported.first { $0.value == uuid }?.key
  }

  /// VoIP 推送里的来电信息。
  struct Incoming: Sendable {
    let id: String
    let caller: String
    let group: String?

    init(_ info: [AnyHashable: Any]) {
      let call = info["call"] as? [String: Any] ?? [:]
      id = call["id"] as? String ?? UUID().uuidString
      caller = call["callerName"] as? String ?? "QQ"
      group = call["groupName"] as? String
    }
  }

  /// 收到 VoIP 推送：报来电，并让 App 连上服务端、拿到这通电话的状态（App 可能是刚被推送拉起来的）。
  private func handleIncoming(_ incoming: Incoming, completion: @escaping @Sendable () -> Void) {
    let id = incoming.id
    let caller = incoming.caller
    let group = incoming.group
    if reported[id] != nil {
      completion()
      return
    }
    let uuid = UUID(uuidString: id) ?? UUID()
    reported[id] = uuid
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: group ?? caller)
    update.localizedCallerName = group.map { "\($0)（\(caller) 邀请）" } ?? caller
    update.hasVideo = false
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      MainActor.assumeIsolated {
        if error != nil { self?.reported[id] = nil }
        completion()
      }
    }
    let model = AppModel.shared
    model.launch()
    model.calls.callKitCallId = id
    startPolling()
  }

  /// CallKit 的通话还在时：连着服务端拿通话状态（对方挂断时收起系统界面）。后台时 App 不连 Subscribe，这里自己问。
  private func startPolling() {
    guard poll == nil else { return }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        await AppModel.shared.calls.refresh(includeEnded: true)
        try? await Task.sleep(for: .seconds(2))
        if self?.reported.isEmpty ?? true { break }
      }
      self?.poll = nil
    }
  }

  private func stopPolling() {
    poll?.cancel()
    poll = nil
  }
}

extension CallKitBridge: PKPushRegistryDelegate {
  nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
    MainActor.assumeIsolated { AppModel.shared.didReceiveVoipToken(hex) }
  }

  nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    let incoming = Incoming(payload.dictionaryPayload)
    nonisolated(unsafe) let done = completion
    MainActor.assumeIsolated { self.handleIncoming(incoming) { done() } }
  }
}

extension CallKitBridge: CXProviderDelegate {
  nonisolated func providerDidReset(_ provider: CXProvider) {
    MainActor.assumeIsolated {
      reported.removeAll()
      stopPolling()
      Task { await AppModel.shared.calls.hangup() }
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    nonisolated(unsafe) let action = action
    let uuid = action.callUUID
    MainActor.assumeIsolated {
      guard let id = callId(for: uuid) else {
        action.fail()
        return
      }
      // 音频会话由 CallKit 激活：LiveKit 先不碰音频设备，等 didActivate 再开。
      AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
      try? AudioManager.shared.setEngineAvailability(.none)
      let session = AVAudioSession.sharedInstance()
      try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      Task {
        await AppModel.shared.calls.answer(callId: id, viaCallKit: true)
      }
      action.fulfill()
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    nonisolated(unsafe) let action = action
    let uuid = action.callUUID
    MainActor.assumeIsolated {
      let id = callId(for: uuid)
      if let id { reported[id] = nil }
      if reported.isEmpty { stopPolling() }
      Task {
        let calls = AppModel.shared.calls
        if id == nil || calls.call?.id == id || calls.call == nil { await calls.hangup(fromCallKit: true, callId: id) }
      }
      action.fulfill()
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    nonisolated(unsafe) let action = action
    let muted = action.isMuted
    MainActor.assumeIsolated {
      Task { await AppModel.shared.calls.setMuted(muted, fromCallKit: true) }
      action.fulfill()
    }
  }

  nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { try? AudioManager.shared.setEngineAvailability(.default) }
  }

  nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { try? AudioManager.shared.setEngineAvailability(.none) }
  }
}
