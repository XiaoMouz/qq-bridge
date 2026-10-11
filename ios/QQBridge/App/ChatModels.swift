// 聊天页的状态与动作：输入框（文字、@ 的人、回复的消息）、群成员（群名片、@ 选人用）、成员头像、语音播放。
import AVFoundation
import Observation
import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 输入框：文字里插入的 "@名字 " 和 "[表情名]" 按插入顺序记下来，发送时拆成 @ 段、表情段。
@MainActor
@Observable
final class Composer {
  var text = ""
  /// 插入过的 @ 和表情：显示用的文字 + 发送用的消息段。
  private var tokens: [(text: String, segment: Qqbridge_V1_OutgoingSegment)] = []
  var replyTo: Qqbridge_V1_Message?
  /// 刚输入了 "@"：弹出选人。
  var pickingMention = false

  func insertMention(userId: Int64, name: String, replacingTrailingAt: Bool = false) {
    if replacingTrailingAt, text.hasSuffix("@") { text.removeLast() }
    if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.mentionUserID = userId
    append("@\(name)", seg, trailingSpace: true)
  }

  func mentionAll() {
    if text.hasSuffix("@") { text.removeLast() }
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.mentionAll = true
    append("@全体成员", seg, trailingSpace: true)
  }

  /// QQ 小黄脸：输入框里显示成 "[微笑]"。
  func insertFace(id: Int, name: String) {
    var seg = Qqbridge_V1_OutgoingSegment()
    seg.faceID = String(id)
    append("[\(name)]", seg, trailingSpace: false)
  }

  private func append(_ token: String, _ seg: Qqbridge_V1_OutgoingSegment, trailingSpace: Bool) {
    text += token + (trailingSpace ? " " : "")
    tokens.append((token, seg))
  }

  /// 拆成发送用的消息段：普通文字、@某人、@全体成员、表情（按出现顺序；被删掉的 @ / 表情就当普通文字）。
  func segments() -> [Qqbridge_V1_OutgoingSegment] {
    var out: [Qqbridge_V1_OutgoingSegment] = []
    var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    func addText(_ s: Substring) {
      guard !s.isEmpty else { return }
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.text = String(s)
      out.append(seg)
    }
    for t in tokens {
      guard let range = rest.range(of: t.text) else { continue }
      addText(rest[..<range.lowerBound])
      out.append(t.segment)
      rest = rest[range.upperBound...]
      if t.text.hasPrefix("@"), rest.hasPrefix(" ") { rest = rest.dropFirst() }
    }
    addText(rest)
    return out
  }

  func reset() {
    text = ""
    tokens = []
    replyTo = nil
  }
}

/// 聊天页里各处要用的动作，由 ChatScreen 实现。
@MainActor
final class ChatActions {
  var reply: (Qqbridge_V1_Message) -> Void = { _ in }
  var mention: (Int64) -> Void = { _ in }
  var showProfile: (Int64) -> Void = { _ in }
  var react: (Qqbridge_V1_Message, String) -> Void = { _, _ in }
  var recall: (Qqbridge_V1_Message) -> Void = { _ in }
  var openMedia: (MediaTarget) -> Void = { _ in }
  var openFile: (Qqbridge_V1_FileSegment) -> Void = { _ in }
  /// 转发这一条（选会话）。
  var forward: (Qqbridge_V1_Message) -> Void = { _ in }
  var playVoice: (Qqbridge_V1_RecordSegment) -> Void = { _ in }
  var openForward: (Qqbridge_V1_Message) -> Void = { _ in }
}

/// 点开的大图或视频。
struct MediaTarget: Identifiable, Hashable {
  enum Kind: Hashable { case image, video }
  let kind: Kind
  let media: Qqbridge_V1_MediaInfo
  /// 所在消息（看大图时向服务端要原图用；合并转发里的没有）。
  var chatId: Int64 = 0
  var seq: Int64 = 0
  var id: String { media.sha256.isEmpty ? "\(chatId):\(seq):\(media.ord):\(media.thumbSha256)" : media.sha256 }
}

/// 群成员（群名片、角色、头衔）：打开群聊时加载一次（服务端有缓存，第一次才向 QQ 要整个成员列表）。
@MainActor
@Observable
final class GroupMembers {
  private(set) var byId: [Int64: Qqbridge_V1_GroupMember] = [:]
  private(set) var list: [Qqbridge_V1_GroupMember] = []
  private var loaded = false

  func load(session: Session, groupId: Int64, refresh: Bool = false) async {
    guard !loaded || refresh else { return }
    loaded = true
    var req = Qqbridge_V1_ListGroupMembersRequest()
    req.groupID = groupId
    req.limit = 2000
    req.refresh = refresh
    guard let res = try? await session.api.contacts.listGroupMembers(request: req, headers: session.api.headers).get() else { return }
    list = res.members
    byId = Dictionary(res.members.map { ($0.userID, $0) }, uniquingKeysWith: { a, _ in a })
  }

  /// 群里显示的名字：群名片 > 昵称。
  func displayName(_ userId: Int64) -> String? {
    guard let m = byId[userId] else { return nil }
    return !m.card.isEmpty ? m.card : (!m.nickname.isEmpty ? m.nickname : nil)
  }
}

/// 头像：显示到谁就批量要谁的（服务端按天缓存，不经 QQ 协议）。人和群分开记。
@MainActor
@Observable
final class AvatarBook {
  private(set) var sha256: [Int64: String] = [:]
  private(set) var groupSha256: [Int64: String] = [:]
  private var requested: Set<Int64> = []
  private var requestedGroups: Set<Int64> = []
  private var pending: Set<Int64> = []
  private var pendingGroups: Set<Int64> = []
  private var flushTask: Task<Void, Never>?

  func want(_ userId: Int64, session: Session) {
    guard userId > 0, !requested.contains(userId) else { return }
    requested.insert(userId)
    pending.insert(userId)
    schedule(session)
  }

  func wantGroup(_ groupId: Int64, session: Session) {
    guard groupId > 0, !requestedGroups.contains(groupId) else { return }
    requestedGroups.insert(groupId)
    pendingGroups.insert(groupId)
    schedule(session)
  }

  private func schedule(_ session: Session) {
    // 攒 150ms 再一起要；不取消已排上的任务（取消会连带取消里面的网络请求，这批头像就丢了）。
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      await self?.flush(session: session)
    }
  }

  private func flush(session: Session) async {
    while !pending.isEmpty || !pendingGroups.isEmpty {
      let ids = Array(pending.prefix(50))
      let groups = Array(pendingGroups.prefix(50 - ids.count))
      pending.subtract(ids)
      pendingGroups.subtract(groups)
      var req = Qqbridge_V1_GetAvatarsRequest()
      req.userIds = ids
      req.groupIds = groups
      if let res = try? await session.api.contacts.getAvatars(request: req, headers: session.api.headers).get() {
        for a in res.avatars { sha256[a.userID] = a.sha256 }
        for a in res.groups { groupSha256[a.userID] = a.sha256 }
      } else {
        // 失败的下次再要。
        requested.subtract(ids)
        requestedGroups.subtract(groups)
      }
    }
    flushTask = nil
  }
}

/// 按需媒体（免打扰、群助手里的群）：图片显示到时、视频文件点开时向服务端要。攒 300ms 一起要，同一个只要一次。
@MainActor
@Observable
final class MediaRequester {
  private var requested: Set<String> = []
  private var pending: [Qqbridge_V1_MediaRef] = []
  private var flushTask: Task<Void, Never>?

  func want(chatId: Int64, seq: Int64, ord: UInt32, session: Session) {
    let key = "\(chatId):\(seq):\(ord)"
    guard seq > 0, !requested.contains(key) else { return }
    requested.insert(key)
    var ref = Qqbridge_V1_MediaRef()
    ref.chatID = chatId
    ref.seq = seq
    ref.ord = ord
    pending.append(ref)
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      await self?.flush(session: session)
    }
  }

  private func flush(session: Session) async {
    while !pending.isEmpty {
      let batch = Array(pending.prefix(100))
      pending.removeFirst(batch.count)
      var req = Qqbridge_V1_RequestMediaRequest()
      req.refs = batch
      if (try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get()) == nil {
        for r in batch { requested.remove("\(r.chatID):\(r.seq):\(r.ord)") }  // 失败的下次再要
      }
    }
    flushTask = nil
  }
}

/// 录语音：按住麦克风开始，松开发送，左滑取消。录成 AAC（m4a），QQ 的 silk 由 NapCat 转。最长 60 秒（QQ 的上限）。
@MainActor
@Observable
final class VoiceRecorder {
  static let maxDuration: TimeInterval = 60
  private(set) var recording = false
  private(set) var elapsed: TimeInterval = 0
  /// 最近的音量（0…1），录音条画波形用。
  private(set) var levels: [CGFloat] = []
  /// 手指已经左滑到取消区。
  var willCancel = false
  /// 录到上限自动结束时调用。
  var onAutoFinish: (() -> Void)?
  private var recorder: AVAudioRecorder?
  private var timer: Timer?

  enum StartError: Error { case denied, unavailable }

  #if DEBUG
  /// 调试：没有麦克风的机器（模拟器跑在没麦克风的 Mac 上）用假的音量走一遍录音条。QQB_FAKE_MIC=1 时启用。
  private var fake: Date?
  private static let fakeMic = ["1", "hold"].contains(ProcessInfo.processInfo.environment["QQB_FAKE_MIC"])
  /// QQB_FAKE_MIC=hold：进入聊天页就开始假录音，不松手（截图看录音条用）。
  static let holdFakeRecording = ProcessInfo.processInfo.environment["QQB_FAKE_MIC"] == "hold"
  #endif

  /// 开始录音。没有麦克风权限 / 录不了（例如没有麦克风）时抛错。
  func start() async throws(StartError) {
    guard !recording else { return }
    #if DEBUG
    if Self.fakeMic {
      fake = Date()
      recording = true
      willCancel = false
      elapsed = 0
      levels = []
      timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let fake = self.fake else { return }
          self.elapsed = Date().timeIntervalSince(fake)
          self.levels.append(CGFloat(0.2 + 0.7 * abs(sin(self.elapsed * 5)) * Double.random(in: 0.5...1)))
          if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
        }
      }
      return
    }
    #endif
    guard await AVAudioApplication.requestRecordPermission() else { throw .denied }
    let audio = AVAudioSession.sharedInstance()
    try? audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try? audio.setActive(true)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 24_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
    guard let r = try? AVAudioRecorder(url: url, settings: settings) else { throw .unavailable }
    r.isMeteringEnabled = true
    guard r.record() else { throw .unavailable }
    recorder = r
    recording = true
    willCancel = false
    elapsed = 0
    levels = []
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private func tick() {
    guard let r = recorder else { return }
    r.updateMeters()
    let db = r.averagePower(forChannel: 0)  // -160…0 dB，人声大多在 -50 以上
    levels.append(CGFloat(max(0, min(1, (db + 50) / 50))))
    if levels.count > 120 { levels.removeFirst(levels.count - 120) }
    elapsed = r.currentTime
    if elapsed >= Self.maxDuration { onAutoFinish?() }
  }

  /// 结束并返回录好的文件和时长；太短（不到 1 秒）返回 nil。
  func finish() -> (url: URL, duration: TimeInterval)? {
    #if DEBUG
    if fake != nil { fake = nil; reset(); return nil }  // 假录音不发送
    #endif
    guard let r = recorder else { return nil }
    let duration = r.currentTime
    r.stop()
    reset()
    guard duration >= 1 else {
      try? FileManager.default.removeItem(at: r.url)
      return nil
    }
    return (r.url, duration)
  }

  func cancel() {
    #if DEBUG
    if fake != nil { fake = nil; reset(); return }
    #endif
    guard let r = recorder else { return }
    r.stop()
    r.deleteRecording()
    reset()
  }

  private func reset() {
    timer?.invalidate()
    timer = nil
    recorder = nil
    recording = false
    willCancel = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

/// 多选：长按"多选"进入，点消息勾选 / 取消，底部按钮逐条转发或合并转发。
@MainActor
@Observable
final class MessageSelection {
  var active = false
  private(set) var seqs: Set<Int64> = []

  func start(with seq: Int64) {
    active = true
    seqs = [seq]
  }

  func toggle(_ seq: Int64) {
    if seqs.contains(seq) { seqs.remove(seq) } else { seqs.insert(seq) }
  }

  func contains(_ seq: Int64) -> Bool { seqs.contains(seq) }

  func end() {
    active = false
    seqs = []
  }
}

/// 语音播放：同一时间只播一条；播的是服务端转好的 AAC（playable），边下边播。
@MainActor
@Observable
final class VoicePlayer {
  private(set) var playing: String?
  private var player: AVPlayer?
  private var observer: NSObjectProtocol?

  func toggle(_ record: Qqbridge_V1_RecordSegment, session: Session) {
    let sha = record.media.playableSha256.isEmpty ? record.media.sha256 : record.media.playableSha256
    if playing == sha {
      stop()
      return
    }
    stop()
    guard !sha.isEmpty else { return }
    playing = sha
    Task {
      guard let url = try? await session.media.streamURL(for: sha), playing == sha else { return }
      try? AVAudioSession.sharedInstance().setCategory(.playback)
      try? AVAudioSession.sharedInstance().setActive(true)
      let item = AVPlayerItem(url: url)
      let player = AVPlayer(playerItem: item)
      self.player = player
      observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.stop() }
      }
      player.play()
    }
  }

  func stop() {
    player?.pause()
    player = nil
    playing = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }
}

/// 跳到某条消息后短暂高亮它。
@MainActor
@Observable
final class MessageHighlight {
  var seq: Int64?

  func flash(_ seq: Int64) {
    self.seq = seq
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.6))
      if self?.seq == seq { self?.seq = nil }
    }
  }
}

/// 聊天页右下角"有人@我"按钮里的一项。
struct MentionTarget: Equatable {
  enum Kind {
    case reply, me, all
  }

  let seq: Int64
  let kind: Kind

  /// 回复我的消息往往也带着 @我（QQ 回复会自动 @ 被回复的人），所以回复优先；@全体成员 只在别的都没有时算。
  init?(seq: Int64, flags: UInt32, includeAll: Bool) {
    self.seq = seq
    if flags & (1 << 8) != 0 {
      kind = .reply
    } else if flags & (1 << 5) != 0 {
      kind = .me
    } else if includeAll, flags & (1 << 6) != 0 {
      kind = .all
    } else {
      return nil
    }
  }
}

/// 聊天页的内存缓存：人名、头像、列表里的消息。单元格渲染时用它，不在主线程上查数据库。
@MainActor
final class ChatLookup {
  private var store: LocalStore?
  private var qqAccountId: Int64 = 0
  private var names: [Int64: String?] = [:]
  private var avatars: [Int64: String?] = [:]
  private var messages: [Int64: Qqbridge_V1_Message] = [:]

  func attach(_ store: LocalStore, qqAccountId id: Int64) {
    guard self.store == nil || id != qqAccountId else { return }
    self.store = store
    qqAccountId = id
    names = [:]
    avatars = [:]
  }

  func update(_ items: [ChatItem]) {
    var map: [Int64: Qqbridge_V1_Message] = [:]
    for item in items { if case .message(let m) = item { map[m.seq] = m } }
    messages = map
  }

  func message(_ seq: Int64) -> Qqbridge_V1_Message? { messages[seq] }

  func userName(_ userId: Int64) -> String? {
    if let cached = names[userId] { return cached }
    let n = try? store?.userName(qqAccountId: qqAccountId, userId: userId)
    names[userId] = .some(n)
    return n
  }

  func avatar(_ userId: Int64) -> String? {
    if let cached = avatars[userId] { return cached }
    let sha = (try? store?.peer(qqAccountId: qqAccountId, kind: .user, peerId: userId))?.avatarSha256
    let value = sha?.isEmpty == false ? sha : nil
    avatars[userId] = .some(value)
    return value
  }
}
