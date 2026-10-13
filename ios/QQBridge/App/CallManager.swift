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
    call = new
    switch new.phase {
    case .ringing:
      startRinging()
    case .ended:
      stopRinging()
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
      let room = Room()
      self.room = room
      try await room.connect(url: res.livekitURL, token: res.livekitToken)
      try await room.localParticipant.setMicrophone(enabled: true)
      joined = true
      applySpeaker()
    } catch {
      self.error = "接听失败：\(LoadState.describe(error))"
      await leaveRoom()
    }
  }

  /// 挂断：响铃中是拒接，接通后是结束通话。
  func hangup() async {
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
    muted.toggle()
    try? await room?.localParticipant.setMicrophone(enabled: !muted)
  }

  func toggleSpeaker() {
    speaker.toggle()
    applySpeaker()
  }

  /// 启动、回到前台时问一次：有没有正在响的来电（推送没点、或 App 刚打开）。
  func refresh() async {
    guard let session else { return }
    guard let res = try? await session.api.calls.getActiveCall(request: .init(), headers: session.api.headers).get() else { return }
    if res.hasCall { update(res.call) }
  }

  private func applySpeaker() {
    AudioManager.shared.isSpeakerOutputPreferred = speaker
  }

  private func leaveRoom() async {
    let r = room
    room = nil
    joined = false
    await r?.disconnect()
  }

  private func reset() {
    stopRinging()
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

/// 全屏通话界面：模糊的大头像做背景，中间名字和状态，底下一排玻璃按钮。
struct CallScreen: View {
  let manager: CallManager
  let session: BridgeSession
  @State private var now = Date()

  private var call: Qqbridge_V1_Call? { manager.call }

  private var peer: Qqbridge_V1_Peer? {
    guard let uin = call?.peerUin, uin > 0 else { return nil }
    return try? session.store.peer(kind: .user, peerId: uin)
  }

  private var name: String {
    if let p = peer, !p.remark.isEmpty { return p.remark }
    if let p = peer, !p.name.isEmpty { return p.name }
    if let n = call?.peerName, !n.isEmpty { return n }
    return call.map { String($0.peerUin) } ?? ""
  }

  private var status: String {
    guard let call else { return "" }
    if let e = manager.error { return e }
    let kind = call.media == .video ? "视频" : "语音"
    switch call.phase {
    case .ringing: return manager.joining ? "正在接通…" : "邀请你\(kind)通话"
    case .accepting, .unspecified: return "正在接通…"
    case .connected:
      if !manager.answeredHere { return "已在其他设备接听" }
      guard call.connectedAt > 0 else { return "通话中" }
      return Format.duration(max(0, Int(now.timeIntervalSince1970) - Int(call.connectedAt)))
    case .ended: return "通话结束"
    default: return ""
    }
  }

  var body: some View {
    ZStack {
      AvatarView(sha256: peer?.avatarSha256, title: name, seed: call?.peerUin ?? 0, size: 600)
        .blur(radius: 60)
        .overlay(Color.black.opacity(0.45))
        .ignoresSafeArea()
      VStack(spacing: 14) {
        Spacer().frame(height: 60)
        AvatarView(sha256: peer?.avatarSha256, title: name, seed: call?.peerUin ?? 0, size: 112)
          .shadow(radius: 12)
        Text(name).font(.title.bold()).foregroundStyle(.white).lineLimit(1)
        Text(status).font(.headline.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        Spacer()
        controls.padding(.bottom, 50)
      }
      .padding(.horizontal, 24)
    }
    .preferredColorScheme(.dark)
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
        CallButton(title: manager.muted ? "取消静音" : "静音", systemImage: manager.muted ? "mic.slash.fill" : "mic.fill", tint: manager.muted ? .white : nil) {
          Task { await manager.toggleMute() }
        }
        Spacer()
        CallButton(title: "挂断", systemImage: "phone.down.fill", tint: .red) { Task { await manager.hangup() } }
        Spacer()
        CallButton(title: "免提", systemImage: manager.speaker ? "speaker.wave.3.fill" : "speaker.fill", tint: manager.speaker ? .white : nil) {
          manager.toggleSpeaker()
        }
      }
    } else {
      // 别的设备接了：这里只能挂断（结束整通电话）。
      CallButton(title: "挂断", systemImage: "phone.down.fill", tint: .red) { Task { await manager.hangup() } }
    }
  }
}

/// 通话界面底部的圆按钮：tint 为 nil 时是玻璃底；白色底时图标反色。
struct CallButton: View {
  let title: String
  let systemImage: String
  var tint: Color?
  let action: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Button(action: action) {
        Image(systemName: systemImage)
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(tint == .white ? Color.black : Color.white)
          .frame(width: 72, height: 72)
          .background {
            if let tint { Circle().fill(tint) }
          }
          .glassEffect(tint == nil ? .regular.interactive() : .identity, in: Circle())
      }
      .buttonStyle(.plain)
      Text(title).font(.footnote).foregroundStyle(.white.opacity(0.85))
    }
  }
}
