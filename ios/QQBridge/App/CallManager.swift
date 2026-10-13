// QQ 语音通话（docs/design.md 5.4）：
// - 来电：服务端经 Subscribe 推 CallUpdate（App 在后台时另有时效性通知）→ 全屏来电界面，响铃、振动。
// - 接听：AnswerCall 拿 LiveKit 的地址和令牌 → 进房间、开麦克风；QQ 那边的声音由通话网关送进同一个房间。
// - 挂断 / 拒接：HangupCall（响铃中是拒接，接通后是结束），然后离开房间。对方挂断时服务端推 ended，这边自动收起。
// - 静音：只关自己的麦克风轨道；免提：切到扬声器。
// 还没有：主动拨打、视频、群通话、CallKit（中国区上架不能用）。
import AudioToolbox
import AVFoundation
import LiveKit
import QQBridgeKit
import QQBridgeProto
import SwiftUI

@MainActor
@Observable
final class CallManager {
  /// 正在显示的通话（结束后留 1.5 秒显示「通话结束」再收起）。
  private(set) var call: Qqbridge_V1_Call?
  /// 已经点了接听，正在进房间。
  private(set) var joining = false
  /// 已经进了 LiveKit 房间。
  private(set) var joined = false
  private(set) var muted = false
  private(set) var speaker = false
  /// 出错时显示一行字。
  private(set) var error: String?
  /// 在这台设备上接的（别的设备接了、或在手机 QQ 上接了，这里只显示「已在其他设备接听」）。
  private(set) var answeredHere = false
  /// 群语音来自免打扰 / 群助手 / 只提醒 @我 的群：不响铃、不弹出，只在会话列表、群聊里显示「语音中」，自己点进去加入。
  private(set) var quiet = false
  /// 群语音所在群的名字（会话列表里的）。
  private(set) var groupTitle: String?
  var isGroup: Bool { (call?.groupID ?? 0) != 0 }
  /// 交给 CallKit（系统来电界面）的那通：响铃由系统负责，App 里不再响铃、不弹来电界面。
  var callKitCallId: String?
  /// 通话界面收起成顶部的小条。
  var minimized = false
  /// 来电时点了顶部的横幅：展开成全屏。
  var expanded = false
  /// 最近的音量（0…1，每 0.1 秒一个，最多 48 个）：对方、自己。
  private(set) var remoteLevels: [Float] = []
  private(set) var localLevels: [Float] = []
  @ObservationIgnored private var meter: Task<Void, Never>?

  @ObservationIgnored private var room: Room?
  @ObservationIgnored private var ringer: Task<Void, Never>?
  @ObservationIgnored private var dismissTask: Task<Void, Never>?
  @ObservationIgnored weak var session: BridgeSession?

  var isRinging: Bool { call?.phase == .ringing && !joining && !answeredHere }
  var ended: Bool { call?.phase == .ended }

  /// 服务端推来的状态（Subscribe 的 CallUpdate、启动时的 GetActiveCall）。
  func update(_ new: Qqbridge_V1_Call) {
    guard new.incoming else { return }
    if let current = call, current.id != new.id, current.phase != .ended, new.phase == .ended { return }
    if call?.id != new.id {
      reset()
      guard new.phase != .ended else { return }  // 已经结束的旧来电（例如重连时收到）不弹出来
    }
    if call?.id != new.id, new.groupID != 0, let session {
      let item = (try? session.store.dialogItems(limit: 5000))?.first { $0.isGroup && $0.dialog.peerID == new.groupID }
      groupTitle = item?.title
      quiet = item == nil || item!.isMuted || ["mentions", "archived", "muted"].contains(item!.dialog.notifyPolicy)
    }
    if callKitCallId == new.id { quiet = true }
    call = new
    switch new.phase {
    case .ringing:
      if !quiet { startRinging() }
    case .ended:
      stopRinging()
      CallKitBridge.shared.reportEnded(new.id, answeredElsewhere: new.connectedAt > 0 && !answeredHere)
      Task { await leaveRoom() }
      dismissTask?.cancel()
      dismissTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(1.5))
        if !Task.isCancelled, self?.call?.id == new.id { self?.reset() }
      }
    default:
      stopRinging()
    }
  }

  /// 从 CallKit 接听：App 可能刚被推送拉起来，还没拿到这通电话的状态，先问一次。
  func answer(callId: String, viaCallKit: Bool) async {
    if call?.id != callId {
      for _ in 0..<10 {
        await refresh()
        if call?.id == callId { break }
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
    guard call?.id == callId else {
      error = "接听失败：找不到这通电话"
      CallKitBridge.shared.reportEnded(callId)
      return
    }
    answeringViaCallKit = viaCallKit
    await answer()
  }

  @ObservationIgnored private var answeringViaCallKit = false

  func answer() async {
    guard let session, let call, call.phase == .ringing || call.phase == .accepting, !joining else { return }
    stopRinging()
    joining = true
    error = nil
    defer { joining = false }
    guard await AVAudioApplication.requestRecordPermission() else {
      error = "没有麦克风权限，到「设置」里打开后再接"
      return
    }
    var req = Qqbridge_V1_AnswerCallRequest()
    req.callID = call.id
    do {
      let res = try await session.api.calls.answerCall(request: req, headers: session.api.headers).get()
      answeredHere = true
      self.call = res.call
      #if targetEnvironment(simulator)
        // 模拟器上系统的语音处理（回声消除）起不来，开麦克风会报 -4010：关掉（真机保留回声消除）。
        try? AudioManager.shared.setVoiceProcessingEnabled(false)
      #endif
      // CallKit 接的：音频会话由 CallKit 管（见 CallKitBridge），这里不用开后台连接以外的东西。
      // 后台时 App 不连 Subscribe：接通后连上，对方挂断时才收得到。
      if answeringViaCallKit { await session.sync.start() }
      let room = Room()
      self.room = room
      try await room.connect(url: res.livekitURL, token: res.livekitToken)
      joined = true
      applySpeaker()
      startMeter(room)
      // 麦克风打不开也留在房间里：至少能听到对方。
      do {
        try await room.localParticipant.setMicrophone(enabled: true)
      } catch {
        muted = true
        self.error = "麦克风打不开，只能听：\(LoadState.describe(error))"
      }
    } catch {
      self.error = "接听失败：\(LoadState.describe(error))"
      await leaveRoom()
    }
  }

  /// 挂断：响铃中是拒接，接通后是结束通话。交给了 CallKit 的那通，先让 CallKit 结束（它再回调这里）。
  func hangup(fromCallKit: Bool = false, callId: String? = nil) async {
    if !fromCallKit, let id = call?.id, CallKitBridge.shared.isReported(id) {
      CallKitBridge.shared.requestEnd(id)
      return
    }
    if call == nil, let callId { await refresh(); guard call?.id == callId else { return } }
    guard let session, let call else { return }
    stopRinging()
    var req = Qqbridge_V1_HangupCallRequest()
    req.callID = call.id
    let res = try? await session.api.calls.hangupCall(request: req, headers: session.api.headers).get()
    await leaveRoom()
    // 服务端随后会推 ended；先自己收起来。
    var ended = res?.call ?? call
    ended.phase = .ended
    update(ended)
  }

  func toggleMute() async {
    if let id = call?.id, CallKitBridge.shared.isReported(id) {
      CallKitBridge.shared.requestMute(id, muted: !muted)
      return
    }
    await setMuted(!muted)
  }

  func setMuted(_ value: Bool, fromCallKit: Bool = false) async {
    muted = value
    try? await room?.localParticipant.setMicrophone(enabled: !value)
  }

  func toggleSpeaker() {
    speaker.toggle()
    applySpeaker()
  }

  /// 启动、回到前台时问一次：有没有正在响的来电（推送没点、或 App 刚打开）。
  /// includeEnded：CallKit 那边还有通话、服务端却已经没有进行中的了——当作结束，收起系统界面。
  func refresh(includeEnded: Bool = false) async {
    guard let session else { return }
    guard let res = try? await session.api.calls.getActiveCall(request: .init(), headers: session.api.headers).get() else { return }
    if res.hasCall {
      update(res.call)
    } else if includeEnded, let id = callKitCallId {
      if var current = call, current.id == id {
        current.phase = .ended
        update(current)
      } else {
        CallKitBridge.shared.reportEnded(id)
      }
    }
  }

  private func applySpeaker() {
    AudioManager.shared.isSpeakerOutputPreferred = speaker
  }

  private func leaveRoom() async {
    meter?.cancel()
    meter = nil
    let r = room
    room = nil
    joined = false
    await r?.disconnect()
  }

  /// 每 0.1 秒记一次双方的音量（通话界面画波形）。
  private func startMeter(_ room: Room) {
    meter?.cancel()
    meter = Task { [weak self] in
      while !Task.isCancelled {
        let remote = room.remoteParticipants.values.map(\.audioLevel).max() ?? 0
        let local = room.localParticipant.audioLevel
        guard let self else { return }
        self.remoteLevels = Array((self.remoteLevels + [remote]).suffix(48))
        self.localLevels = Array((self.localLevels + [self.muted ? 0 : local]).suffix(48))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func reset() {
    stopRinging()
    meter?.cancel()
    meter = nil
    remoteLevels = []
    localLevels = []
    minimized = false
    expanded = false
    quiet = false
    groupTitle = nil
    callKitCallId = nil
    answeringViaCallKit = false
    // CallKit 接的通话关掉了 LiveKit 的自动音频配置，结束后恢复（App 里接的通话靠它）。
    AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
    try? AudioManager.shared.setEngineAvailability(.default)
    dismissTask?.cancel()
    call = nil
    joining = false
    joined = false
    muted = false
    speaker = false
    error = nil
    answeredHere = false
    let r = room
    room = nil
    Task { await r?.disconnect() }
  }

  /// 响铃：每 2 秒一声系统提示音加振动，最多 60 秒（QQ 那边也差不多这么久就算未接）。
  private func startRinging() {
    guard ringer == nil else { return }
    ringer = Task {
      for _ in 0..<30 {
        if Task.isCancelled { return }
        AudioServicesPlayAlertSound(SystemSoundID(1005))
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func stopRinging() {
    ringer?.cancel()
    ringer = nil
  }
}

/// 通话的显示：名字、头像、状态文字（几个界面共用）。
@MainActor
struct CallInfo {
  let manager: CallManager
  let session: BridgeSession
  var now = Date()

  var call: Qqbridge_V1_Call? { manager.call }

  var peer: Qqbridge_V1_Peer? {
    guard let uin = call?.peerUin, uin > 0 else { return nil }
    return try? session.store.peer(kind: .user, peerId: uin)
  }

  /// 头像：群语音用群头像。
  var avatarSha: String? {
    if manager.isGroup, let gid = call?.groupID { return (try? session.store.peer(kind: .group, peerId: gid))?.avatarSha256 }
    return peer?.avatarSha256
  }

  var avatarSeed: Int64 { manager.isGroup ? (call?.groupID ?? 0) : (call?.peerUin ?? 0) }

  /// 邀请人（群语音）/ 对方（1 对 1）。
  var callerName: String {
    if let p = peer, !p.remark.isEmpty { return p.remark }
    if let p = peer, !p.name.isEmpty { return p.name }
    if let n = call?.peerName, !n.isEmpty { return n }
    return call.map { String($0.peerUin) } ?? ""
  }

  /// 界面上的标题：群语音是群名，1 对 1 是对方。
  var name: String {
    if manager.isGroup { return manager.groupTitle ?? String(call?.groupID ?? 0) }
    if let p = peer, !p.remark.isEmpty { return p.remark }
    if let p = peer, !p.name.isEmpty { return p.name }
    if let n = call?.peerName, !n.isEmpty { return n }
    return call.map { String($0.peerUin) } ?? ""
  }

  var kind: String { call?.media == .video ? "视频" : "语音" }

  var duration: String? {
    guard let call, call.phase == .connected, manager.answeredHere, call.connectedAt > 0 else { return nil }
    return Format.duration(max(0, Int(now.timeIntervalSince1970) - Int(call.connectedAt)))
  }

  var status: String {
    guard let call else { return "" }
    if let e = manager.error { return e }
    switch call.phase {
    case .ringing:
      if manager.joining { return "正在接通…" }
      return manager.isGroup ? "\(callerName) 邀请你加入群\(kind)通话" : "邀请你\(kind)通话"
    case .accepting, .unspecified: return "正在接通…"
    case .connected: return manager.answeredHere ? (duration ?? "通话中") : "已在其他设备接听"
    case .ended: return "通话结束"
    default: return ""
    }
  }
}

/// 全屏通话界面（系统背景色）：来电时头像、名字、拒绝 / 接听；通话中计时、双方的音量波形、静音 / 挂断 / 免提。
struct CallScreen: View {
  let manager: CallManager
  let session: BridgeSession
  @State private var now = Date()

  var body: some View {
    let info = CallInfo(manager: manager, session: session, now: now)
    VStack(spacing: 12) {
      HStack {
        if manager.answeredHere || manager.joining {
          Button { manager.minimized = true } label: {
            Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
          }
          .buttonStyle(.glass)
          .accessibilityLabel("收起")
        }
        Spacer()
      }
      .padding(.top, 8)
      Spacer().frame(height: 40)
      AvatarView(sha256: info.avatarSha, title: info.name, seed: info.avatarSeed, size: 104)
      Text(info.name).font(.title.bold()).lineLimit(1)
      Text(info.status)
        .font(.headline.monospacedDigit())
        .foregroundStyle(manager.error == nil ? .secondary : Color.red)
        .multilineTextAlignment(.center)
      if manager.joined {
        VStack(spacing: 14) {
          LevelWave(levels: manager.remoteLevels, color: .accentColor, label: "对方")
          LevelWave(levels: manager.localLevels, color: .green, label: manager.muted ? "我（静音）" : "我")
        }
        .padding(.top, 28)
      }
      Spacer()
      controls.padding(.bottom, 40)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground).ignoresSafeArea())
    .task {
      while !Task.isCancelled {
        now = Date()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  @ViewBuilder private var controls: some View {
    if manager.ended {
      EmptyView()
    } else if manager.isRinging {
      HStack {
        CallButton(title: "拒绝", systemImage: "phone.down.fill", tint: .red) { Task { await manager.hangup() } }
        Spacer()
        CallButton(title: "接听", systemImage: "phone.fill", tint: .green) { Task { await manager.answer() } }
      }
      .padding(.horizontal, 30)
    } else if manager.answeredHere || manager.joining {
      HStack {
        CallButton(title: manager.muted ? "取消静音" : "静音", systemImage: manager.muted ? "mic.slash.fill" : "mic.fill", selected: manager.muted) {
          Task { await manager.toggleMute() }
        }
        Spacer()
        CallButton(title: "挂断", systemImage: "phone.down.fill", tint: .red) { Task { await manager.hangup() } }
        Spacer()
        CallButton(title: "免提", systemImage: manager.speaker ? "speaker.wave.3.fill" : "speaker.fill", selected: manager.speaker) {
          manager.toggleSpeaker()
        }
      }
    } else {
      // 别的设备接了：这里只能挂断（结束整通电话）。
      CallButton(title: "挂断", systemImage: "phone.down.fill", tint: .red) { Task { await manager.hangup() } }
    }
  }
}

/// 音量波形：最近 4.8 秒，每 0.1 秒一根，新的在右边。
struct LevelWave: View {
  let levels: [Float]
  let color: Color
  let label: String

  var body: some View {
    HStack(spacing: 10) {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
      HStack(alignment: .center, spacing: 2) {
        let padded = Array(repeating: Float(0), count: max(0, 48 - levels.count)) + levels
        ForEach(padded.indices, id: \.self) { i in
          // 音量是线性的 0…1，说话时一般只有 0.05–0.3：开个方让小声也看得见。
          let v = CGFloat(min(1, sqrt(Double(padded[i])) * 1.4))
          Capsule().fill(color.opacity(v > 0.05 ? 1 : 0.3)).frame(width: 3, height: 3 + 33 * v)
        }
      }
      .frame(height: 36)
      .animation(.linear(duration: 0.1), value: levels)
    }
  }
}

/// 通话按钮：tint 是实心色（接听、挂断）；没有 tint 时是灰底，选中（静音、免提开着）时反色。
struct CallButton: View {
  let title: String
  let systemImage: String
  var tint: Color? = nil
  var selected = false
  let action: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Button(action: action) {
        Image(systemName: systemImage)
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(tint != nil ? Color.white : selected ? Color(.systemBackground) : Color.primary)
          .frame(width: 72, height: 72)
          .background(Circle().fill(tint ?? (selected ? Color.primary : Color(.secondarySystemFill))))
      }
      .buttonStyle(.plain)
      Text(title).font(.footnote).foregroundStyle(.secondary)
    }
  }
}

/// 顶部的通话横幅：来电时（不在消息页）带拒绝 / 接听，点一下展开成全屏；通话收起后是绿色的小条，点一下回到通话界面。
struct CallBanner: View {
  let manager: CallManager
  let session: BridgeSession
  @State private var now = Date()

  var body: some View {
    let info = CallInfo(manager: manager, session: session, now: now)
    Group {
      if manager.isRinging {
        HStack(spacing: 12) {
          AvatarView(sha256: info.avatarSha, title: info.name, seed: info.avatarSeed, size: 44)
          VStack(alignment: .leading, spacing: 2) {
            Text(info.name).font(.headline).lineLimit(1)
            Text(info.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 8)
          bannerButton("phone.down.fill", .red) { Task { await manager.hangup() } }
          bannerButton("phone.fill", .green) { Task { await manager.answer() } }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        .contentShape(Rectangle())
        .onTapGesture { manager.expanded = true }
        .padding(.horizontal, 10)
      } else {
        Button { manager.minimized = false } label: {
          HStack(spacing: 8) {
            Image(systemName: "phone.fill")
            Text("\(info.name) · \(info.status)").lineLimit(1)
          }
          .font(.subheadline.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .background(Capsule().fill(Color.green))
        }
        .buttonStyle(.plain)
      }
    }
    .task {
      while !Task.isCancelled {
        now = Date()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func bannerButton(_ image: String, _ color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: image).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
        .frame(width: 44, height: 44).background(Circle().fill(color))
    }
    .buttonStyle(.plain)
  }
}
