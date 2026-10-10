// 聊天页的状态与动作：输入框（文字、@ 的人、回复的消息）、群成员（群名片、@ 选人用）、成员头像、语音播放。
import AVFoundation
import Observation
import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 输入框：文字里的 "@名字 " 记在 mentions 里，发送时按出现顺序拆成 @ 段。
@MainActor
@Observable
final class Composer {
  var text = ""
  var mentions: [(userId: Int64, name: String)] = []
  var replyTo: Qqbridge_V1_Message?
  /// 刚输入了 "@"：弹出选人。
  var pickingMention = false

  func insertMention(userId: Int64, name: String, replacingTrailingAt: Bool = false) {
    if replacingTrailingAt, text.hasSuffix("@") { text.removeLast() }
    if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
    text += "@\(name) "
    mentions.append((userId, name))
  }

  func mentionAll() {
    if text.hasSuffix("@") { text.removeLast() }
    text += "@全体成员 "
    mentions.append((0, "全体成员"))
  }

  /// 拆成发送用的消息段：普通文字、@某人、@全体成员。
  func segments() -> [Qqbridge_V1_OutgoingSegment] {
    var out: [Qqbridge_V1_OutgoingSegment] = []
    var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    func addText(_ s: Substring) {
      guard !s.isEmpty else { return }
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.text = String(s)
      out.append(seg)
    }
    for m in mentions {
      let token = "@\(m.name)"
      guard let range = rest.range(of: token) else { continue }
      addText(rest[..<range.lowerBound])
      var seg = Qqbridge_V1_OutgoingSegment()
      if m.userId == 0 { seg.mentionAll = true } else { seg.mentionUserID = m.userId }
      out.append(seg)
      rest = rest[range.upperBound...]
      if rest.hasPrefix(" ") { rest = rest.dropFirst() }
    }
    addText(rest)
    return out
  }

  func reset() {
    text = ""
    mentions = []
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
  var playVoice: (Qqbridge_V1_RecordSegment) -> Void = { _ in }
  var openForward: (Qqbridge_V1_Message) -> Void = { _ in }
}

/// 点开的大图或视频。
struct MediaTarget: Identifiable, Hashable {
  enum Kind: Hashable { case image, video }
  let kind: Kind
  let media: Qqbridge_V1_MediaInfo
  var id: String { media.sha256.isEmpty ? media.thumbSha256 : media.sha256 }
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

/// 成员头像：聊天页显示到谁就批量要谁的（服务端按天缓存，不经 QQ 协议）。
@MainActor
@Observable
final class AvatarBook {
  private(set) var sha256: [Int64: String] = [:]
  private var requested: Set<Int64> = []
  private var pending: Set<Int64> = []
  private var flushTask: Task<Void, Never>?

  func want(_ userId: Int64, session: Session) {
    guard userId > 0, !requested.contains(userId) else { return }
    requested.insert(userId)
    pending.insert(userId)
    // 攒 150ms 再一起要；不取消已排上的任务（取消会连带取消里面的网络请求，这批头像就丢了）。
    guard flushTask == nil else { return }
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      await self?.flush(session: session)
    }
  }

  private func flush(session: Session) async {
    while !pending.isEmpty {
      let ids = Array(pending.prefix(50))
      pending.subtract(ids)
      var req = Qqbridge_V1_GetAvatarsRequest()
      req.userIds = ids
      if let res = try? await session.api.contacts.getAvatars(request: req, headers: session.api.headers).get() {
        for a in res.avatars { sha256[a.userID] = a.sha256 }
      } else {
        requested.subtract(ids)  // 失败的下次再要
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
