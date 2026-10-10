// 一行聊天内容：消息气泡、服务事件灰条、发件箱里还没发出去的消息。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct MessageContext {
  let selfUin: Int64
  let isGroup: Bool
  let qqAccountId: Int64
  let chatId: Int64
  let store: LocalStore
  let members: GroupMembers
  let avatars: AvatarBook
  let requester: MediaRequester
  let selection: MessageSelection
  let voice: VoicePlayer
  let actions: ChatActions
  let session: Session

  /// 显示名：我 > 群名片 / 昵称 > 联系人备注 / 昵称 > 号码。
  @MainActor
  func name(of userId: Int64) -> String {
    if userId == selfUin { return "我" }
    if isGroup, let n = members.displayName(userId) { return n }
    return (try? store.userName(qqAccountId: qqAccountId, userId: userId)) ?? String(userId)
  }
}

struct MessageRow: View {
  let item: ChatItem
  let context: MessageContext
  let previous: ChatItem?

  var body: some View {
    VStack(spacing: 6) {
      if showsTime {
        Text(Format.chatTime(item.time)).font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
      }
      switch item {
      case .event(let e):
        Notice(text: EventText.describe(e, context: context))
      case .message(let m) where m.state == .recalled:
        Notice(text: m.senderID == context.selfUin ? "你撤回了一条消息" : "\(context.name(of: m.senderID)) 撤回了一条消息")
      case .message(let m):
        if context.selection.active {
          // 多选：左边一个勾，整行点一下勾选 / 取消（不再打开图片、播放语音）。
          HStack(spacing: 8) {
            Image(systemName: context.selection.contains(m.seq) ? "checkmark.circle.fill" : "circle")
              .font(.title3)
              .foregroundStyle(context.selection.contains(m.seq) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
              .padding(.leading, 12)
            MessageBubbleRow(message: m, context: context, showsSender: showsSender(m))
              .allowsHitTesting(false)
          }
          .contentShape(Rectangle())
          .onTapGesture { context.selection.toggle(m.seq) }
        } else {
          MessageBubbleRow(message: m, context: context, showsSender: showsSender(m))
        }
      case .outgoing(let o):
        OutgoingRow(entry: o, session: context.session)
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// 和上一条隔了 5 分钟以上才显示时间。
  private var showsTime: Bool {
    guard let previous else { return true }
    return item.time - previous.time > 300
  }

  /// 群里，连续同一个人发的只在第一条显示名字和头像。
  private func showsSender(_ m: Qqbridge_V1_Message) -> Bool {
    guard context.isGroup, m.senderID != context.selfUin else { return false }
    if showsTime { return true }
    if case .message(let p)? = previous, p.senderID == m.senderID, p.state != .recalled { return false }
    return true
  }
}

struct Notice: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(.quaternary.opacity(0.5), in: Capsule())
  }
}

/// 常用的表情回应（QQ 的 emoji 回应用码点做 id）。
let quickReactions: [(id: String, label: String)] = [
  ("128077", "👍"), ("10084", "❤️"), ("128514", "😂"), ("128558", "😮"), ("128546", "😢"), ("127881", "🎉"),
]

struct MessageBubbleRow: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext

  let showsSender: Bool

  private var outgoing: Bool { message.senderID == context.selfUin }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if outgoing { Spacer(minLength: 48) }
      if context.isGroup, !outgoing {
        if showsSender {
          SenderAvatar(userId: message.senderID, context: context)
        } else {
          Color.clear.frame(width: 34, height: 1)
        }
      }
      VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
        if showsSender {
          HStack(spacing: 4) {
            Text(context.name(of: message.senderID)).font(.caption).foregroundStyle(.secondary)
            if let m = context.members.byId[message.senderID] {
              if m.role == "owner" { RoleTag(text: "群主", color: .orange) } else if m.role == "admin" { RoleTag(text: "管理员", color: .green) }
              if !m.title.isEmpty { RoleTag(text: m.title, color: .purple) }
            }
          }
        }
        MessageContent(message: message, context: context, outgoing: outgoing)
          .contextMenu { menu }
        if !message.reactions.isEmpty { Reactions(message: message, context: context) }
      }
      if !outgoing { Spacer(minLength: 48) }
    }
  }

  @ViewBuilder private var menu: some View {
    Button("回复", systemImage: "arrowshape.turn.up.left") { context.actions.reply(message) }
    Button("转发", systemImage: "arrowshape.turn.up.right") { context.actions.forward(message) }
    Button("多选", systemImage: "checkmark.circle") { context.selection.start(with: message.seq) }
    if !message.text.isEmpty {
      Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
    }
    if context.isGroup, !outgoing {
      Button("@\(context.name(of: message.senderID))", systemImage: "at") { context.actions.mention(message.senderID) }
    }
    if context.isGroup {
      Menu("回应", systemImage: "face.smiling") {
        ForEach(quickReactions, id: \.id) { r in
          Button(r.label) { context.actions.react(message, r.id) }
        }
      }
    }
    if outgoing, Date().timeIntervalSince1970 - Double(message.time) < 120 {
      Button("撤回", systemImage: "arrow.uturn.backward", role: .destructive) { context.actions.recall(message) }
    }
  }
}

/// 群友头像：点开看资料，长按 @ 他。头像按需向服务端要（显示到谁要谁的）。
struct SenderAvatar: View {
  let userId: Int64
  let context: MessageContext

  var body: some View {
    let name = context.name(of: userId)
    let sha = context.avatars.sha256[userId]
      ?? (try? context.store.peer(qqAccountId: context.qqAccountId, kind: .user, peerId: userId))?.avatarSha256
    AvatarView(sha256: sha, title: name, seed: userId, size: 34)
      .onAppear { context.avatars.want(userId, session: context.session) }
      .onTapGesture { context.actions.showProfile(userId) }
      .onLongPressGesture(minimumDuration: 0.4) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        context.actions.mention(userId)
      }
  }
}

struct RoleTag: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
      .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(color)
  }
}

/// 气泡内容：按消息段排版。只有一张图 / 一个表情时不画气泡底色。
struct MessageContent: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext
  let outgoing: Bool

  var body: some View {
    let blocks = Block.make(message.segments, context: context)
    let bare = blocks.count == 1 && blocks[0].isBare
    VStack(alignment: .leading, spacing: 6) {
      ForEach(blocks.indices, id: \.self) { i in
        BlockView(block: blocks[i], context: context, outgoing: outgoing, message: message)
      }
    }
    .padding(bare ? 0 : 10)
    .background {
      if !bare {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(outgoing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemBackground)))
      }
    }
    .foregroundStyle(outgoing && !bare ? Color.white : Color.primary)
  }
}

/// 排版块：相邻的文字、@、表情合成一段富文本，其余各成一块。
enum Block {
  case text([Inline])
  case reply(Int64)
  case image(Qqbridge_V1_ImageSegment)
  case sticker(media: Qqbridge_V1_MediaInfo, summary: String)
  case record(Qqbridge_V1_RecordSegment)
  case video(Qqbridge_V1_VideoSegment)
  case file(Qqbridge_V1_FileSegment)
  case forward(Qqbridge_V1_ForwardSegment)
  case card(String)

  var isBare: Bool {
    switch self {
    case .sticker: true
    case .image(let i): i.sticker
    case .text(let runs): Inline.jumboFaces(runs) != nil
    default: false
    }
  }

  @MainActor static func make(_ segments: [Qqbridge_V1_Segment], context: MessageContext) -> [Block] {
    var out: [Block] = []
    var runs: [Inline] = []
    var text = AttributedString()
    func cut() {
      if !text.characters.isEmpty { runs.append(.text(text)) }
      text = AttributedString()
    }
    func flush() {
      cut()
      if !runs.isEmpty { out.append(.text(runs)) }
      runs = []
    }
    for seg in segments {
      switch seg.kind {
      case .text(let t): text += AttributedString(t.text)
      case .mention(let m):
        var a = AttributedString("@\(m.name.isEmpty ? context.name(of: m.userID) : m.name) ")
        a.font = .body.bold()
        text += a
      case .mentionAll:
        var a = AttributedString("@全体成员 ")
        a.font = .body.bold()
        text += a
      case .face(let f): cut(); runs.append(.face(f.faceID, name: f.name, large: f.isLarge))
      case .reply(let r): out.insert(.reply(r.seq), at: 0)
      case .image(let i):
        flush()
        out.append(i.sticker ? .sticker(media: i.media, summary: i.summary) : .image(i))
      case .record(let r): flush(); out.append(.record(r))
      case .video(let v): flush(); out.append(.video(v))
      case .file(let f): flush(); out.append(.file(f))
      case .forward(let f): flush(); out.append(.forward(f))
      case .marketFace(let f):
        flush()
        if f.hasMedia, !f.media.sha256.isEmpty {
          out.append(.sticker(media: f.media, summary: f.summary))
        } else {
          out.append(.text([.text(AttributedString(f.summary.isEmpty ? "[表情]" : f.summary))]))
        }
      case .lightApp(let a): flush(); out.append(.card(CardText.from(json: a.json, app: a.appName)))
      case .xml: flush(); out.append(.card("[卡片消息]"))
      case .markdown(let m): text += (try? AttributedString(markdown: m.content)) ?? AttributedString(m.content)
      case .unknown(let u):
        switch u.original {
        case "keyboard": break  // 机器人按钮：只能在 QQ 里点
        case "dice": text += AttributedString("[骰子]")
        case "rps": text += AttributedString("[猜拳]")
        default: text += AttributedString("[暂不支持的消息]")
        }
      case .none: break
      }
    }
    flush()
    return out
  }
}

struct BlockView: View {
  let block: Block
  let context: MessageContext
  let outgoing: Bool
  var message: Qqbridge_V1_Message? = nil

  var body: some View {
    switch block {
    case .text(let runs):
      if let faces = Inline.jumboFaces(runs) {
        // 只有 1–3 个 QQ 表情：放大显示，不要气泡（和 Telegram 的单 emoji 消息一样）。
        let size: CGFloat = faces.count == 1 ? 72 : 52
        HStack(spacing: 4) {
          ForEach(faces.indices, id: \.self) { i in QQFace.inline(faces[i].id, name: faces[i].name, size: size) }
        }
      } else {
        Inline.compose(runs).textSelection(.enabled)
      }
    case .reply(let seq):
      ReplyQuote(seq: seq, context: context, outgoing: outgoing)
    case .image(let i):
      MediaThumb(media: i.media, width: i.width, height: i.height, chatId: context.chatId, onNeedThumb: { requestMedia(i.media) })
        .onTapGesture { context.actions.openMedia(MediaTarget(kind: .image, media: i.media, chatId: context.chatId, seq: message?.seq ?? 0)) }
    case .sticker(let media, let summary):
      // 表情用原图（会动）；原图还没有时先显示以前的缩略图，不常用会话里显示到时才向服务端要原图。
      let sha = media.state == .stored && !media.sha256.isEmpty ? media.sha256 : (media.thumbSha256.isEmpty ? nil : media.thumbSha256)
      CachedImage(sha256: sha, chatId: context.chatId, maxPixel: 420, animated: true) {
        Text(summary.isEmpty ? "[表情]" : summary).font(.caption).foregroundStyle(.secondary)
      }
      .aspectRatio(contentMode: .fit)
      .frame(maxWidth: 140, maxHeight: 140)
      .onAppear { if media.state == .onDemand { requestMedia(media) } }
    case .record(let r):
      VoiceBubble(record: r, playing: context.voice.playing != nil && [r.media.playableSha256, r.media.sha256].contains(context.voice.playing!))
        .contentShape(Rectangle())
        .onTapGesture { context.actions.playVoice(r) }
    case .video(let v):
      MediaThumb(media: v.media, width: v.width, height: v.height, chatId: context.chatId)
        .onTapGesture {
          // 按需的视频：点一下开始下载，下好后再点播放。
          if v.media.state == .onDemand { requestMedia(v.media) } else { context.actions.openMedia(MediaTarget(kind: .video, media: v.media, chatId: context.chatId, seq: message?.seq ?? 0)) }
        }
        .overlay {
          Image(systemName: v.media.state == .onDemand ? "arrow.down.circle.fill" : v.media.state == .pending ? "hourglass.circle.fill" : "play.circle.fill")
            .font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
        }
        .overlay(alignment: .bottomTrailing) {
          if v.durationSec > 0 {
            Text(Format.duration(Int(v.durationSec))).font(.caption2.monospacedDigit()).padding(4)
              .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(6)
          }
        }
    case .file(let f):
      HStack(spacing: 10) {
        Image(systemName: fileIcon(f.media.state)).font(.title2)
        VStack(alignment: .leading) {
          Text(f.name).lineLimit(2)
          Text(fileStatus(f)).font(.caption).opacity(0.7)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture {
        switch f.media.state {
        case .onDemand: requestMedia(f.media)
        case .stored, .purged: context.actions.openFile(f)
        default: break
        }
      }
    case .forward(let f):
      VStack(alignment: .leading, spacing: 4) {
        Text(f.title.isEmpty ? "聊天记录" : f.title).font(.subheadline.bold())
        ForEach(Array(f.preview.prefix(4).enumerated()), id: \.offset) { _, line in
          Text(line).font(.caption).lineLimit(1).opacity(0.8)
        }
        Divider()
        Text(f.summary.isEmpty ? "查看聊天记录" : f.summary).font(.caption2).opacity(0.7)
      }
      .frame(minWidth: 180, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture { if let m = message { context.actions.openForward(m) } }
    case .card(let text):
      Label(text, systemImage: "rectangle.on.rectangle").font(.subheadline)
    }
  }

  private func requestMedia(_ media: Qqbridge_V1_MediaInfo) {
    guard let message else { return }
    context.requester.want(chatId: context.chatId, seq: message.seq, ord: media.ord, session: context.session)
  }

  private func fileIcon(_ state: Qqbridge_V1_MediaState) -> String {
    switch state {
    case .onDemand: "arrow.down.doc.fill"
    case .pending: "hourglass"
    case .expired, .failed: "doc.badge.ellipsis"
    default: "doc.fill"
    }
  }

  private func fileStatus(_ f: Qqbridge_V1_FileSegment) -> String {
    let size = ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)
    switch f.media.state {
    case .onDemand: return "\(size) · 点击下载"
    case .pending: return "\(size) · 下载中"
    case .expired: return "\(size) · 已过期"
    case .failed: return "\(size) · 下载失败"
    default: return size
    }
  }
}

/// 图片 / 视频封面：按原始比例显示缩略图，先用占位色块撑住大小，滚动时不跳。
struct MediaThumb: View {
  let media: Qqbridge_V1_MediaInfo
  let width: UInt32
  let height: UInt32
  let chatId: Int64
  /// 没有缩略图时调用（向服务端要 QQ 缩略图）。
  var onNeedThumb: (() -> Void)? = nil
  @Environment(\.session) private var session
  @State private var localOriginal = false

  /// 显示哪张：手机上已有原图就显示原图（缩小解码），否则 QQ 缩略图；都没有时服务端有原图就下原图。
  private var displaySha: String? {
    if localOriginal { return media.sha256 }
    if !media.thumbSha256.isEmpty { return media.thumbSha256 }
    if media.state == .stored, !media.sha256.isEmpty { return media.sha256 }
    return nil
  }

  var body: some View {
    let w = CGFloat(max(width, media.width, 1))
    let h = CGFloat(max(height, media.height, 1))
    let ratio = min(max(w / h, 0.4), 2.5)
    let maxW: CGFloat = 220
    let size = ratio >= 1 ? CGSize(width: maxW, height: maxW / ratio) : CGSize(width: maxW * ratio, height: maxW)
    CachedImage(sha256: displaySha, chatId: chatId, maxPixel: 720, animated: localOriginal) {
      ZStack {
        Rectangle().fill(.quaternary)
        if media.state == .expired || media.state == .failed {
          Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
        } else if displaySha == nil {
          ProgressView()
        }
      }
    }
    .aspectRatio(contentMode: .fill)
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .task(id: media.sha256) {
      guard !media.sha256.isEmpty, let session else { return }
      localOriginal = (try? await session.media.cachedFile(media.sha256)) != nil
    }
    .onAppear { if media.thumbSha256.isEmpty, media.state != .stored { onNeedThumb?() } }
  }
}

/// 语音：波形 + 时长，点一下播放 / 停止。
struct VoiceBubble: View {
  let record: Qqbridge_V1_RecordSegment
  var playing = false

  var body: some View {
    let bars = Array(record.media.waveform)
    let seconds = Int(record.durationSec)
    HStack(spacing: 8) {
      Image(systemName: playing ? "stop.fill" : "play.fill")
      HStack(alignment: .center, spacing: 2) {
        ForEach(0..<max(bars.count, 1), id: \.self) { i in
          let v = bars.isEmpty ? 0.3 : CGFloat(bars[i]) / 255
          Capsule().frame(width: 2, height: 4 + 18 * v)
        }
      }
      .frame(width: CGFloat(min(160, 60 + seconds * 4)), alignment: .leading)
      .clipped()
      Text("\(seconds)″").font(.caption.monospacedDigit())
    }
  }
}

struct ReplyQuote: View {
  let seq: Int64
  let context: MessageContext
  let outgoing: Bool
  @Environment(\.session) private var session
  @State private var original: Qqbridge_V1_Message?
  @State private var missing = false

  var body: some View {
    HStack(spacing: 6) {
      Rectangle().frame(width: 3).opacity(0.6)
      VStack(alignment: .leading, spacing: 1) {
        if let original {
          Text(context.name(of: original.senderID)).font(.caption.bold())
          Text(Format.preview(original)).font(.caption).lineLimit(2)
        } else {
          Text(missing ? "原消息已无法找到" : "…").font(.caption)
        }
      }
      .opacity(0.85)
    }
    .fixedSize(horizontal: false, vertical: true)
    .task(id: seq) {
      // 本地有就直接用；没有就向服务端要这一条（服务端没有的会现场向 QQ 拉）。
      if let local = try? context.store.message(chatId: context.chatId, seq: seq) {
        original = local
      } else if let fetched = await session?.sync.fetchMessage(chatId: context.chatId, seq: seq) {
        original = fetched
      } else {
        missing = true
      }
    }
  }
}

struct Reactions: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext
  var body: some View {
    HStack(spacing: 4) {
      ForEach(message.reactions, id: \.emojiID) { r in
        Button {
          if context.isGroup { context.actions.react(message, r.emojiID) }
        } label: {
          HStack(spacing: 2) {
            QQFace.view(r.emojiID)
            Text("\(r.count)").monospacedDigit()
          }
          .font(.caption)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(r.me ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

/// 还在发件箱里的消息（发送中 / 失败）。
struct OutgoingRow: View {
  let entry: Qqbridge_V1_OutboxEntry
  let session: Session

  var body: some View {
    HStack(alignment: .bottom, spacing: 6) {
      Spacer(minLength: 48)
      switch entry.state {
      case .failed:
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
      default:
        Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
      }
      Text(entry.segments.map { seg in
        switch seg.kind {
        case .text(let t): t
        case .image: "[图片]"
        case .video: "[视频]"
        case .record: "[语音]"
        case .file: "[文件]"
        case .faceID(let f): QQFace.text(f)
        case .mentionUserID(let u): "@\(u) "
        case .mentionAll: "@全体成员 "
        case .forward(let f): "[聊天记录] \(f.nodes.count) 条"
        case .none: ""
        }
      }.joined())
      .padding(10)
      .background(Color.accentColor.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .foregroundStyle(.white)
    }
    .contextMenu {
      if entry.state == .failed {
        if !entry.error.isEmpty { Text(entry.error) }
        Button("重新发送", systemImage: "arrow.clockwise") {
          Task { try? await session.sender.resend(entry) }
        }
        Button("删除", systemImage: "trash", role: .destructive) {
          try? session.store.deleteLocalOutbox(clientRandomId: entry.clientRandomID)
        }
      }
    }
  }
}

/// 一段富文本里的一截：文字或小黄脸。
enum Inline {
  case text(AttributedString)
  case face(String, name: String, large: Bool)

  /// 整段只有 1–3 个 QQ 表情（可夹空白）时返回它们，用来放大显示。
  static func jumboFaces(_ runs: [Inline]) -> [(id: String, name: String)]? {
    var faces: [(id: String, name: String)] = []
    for run in runs {
      switch run {
      case .face(let id, let name, _): faces.append((id, name))
      case .text(let a): if !String(a.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
      }
    }
    return (1...3).contains(faces.count) ? faces : nil
  }

  @MainActor static func compose(_ runs: [Inline]) -> Text {
    runs.reduce(Text(verbatim: "")) { acc, run in
      switch run {
      case .text(let a): Text("\(acc)\(Text(a))")
      case .face(let id, let name, let large): Text("\(acc)\(QQFace.inline(id, name: name, size: large ? 64 : 20))")
      }
    }
  }
}

/// QQ 小黄脸：图和名字取自 QQ 自带的表情资源（Resources/QQFaces、QQFaceNames.swift）；
/// 新出的表情本地没有就显示名字或编号。emoji 回应的 id 是码点。
enum QQFace {
  /// 纯文字场景（引用、预览）：[微笑]。
  static func text(_ id: String, name: String = "") -> String {
    if let code = Int(id), code > 0x2000, let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
    if !name.isEmpty { return "[\(name)]" }
    if let code = Int(id), let name = names[code] { return "[\(name)]" }
    return "[表情]"
  }

  /// 行内：有图用图（按正文字号缩放），没有就退回文字。
  @MainActor static func inline(_ id: String, name: String = "", size: CGFloat = 20) -> Text {
    guard let image = image(id, size: size) else { return Text(verbatim: text(id, name: name)) }
    return Text(Image(uiImage: image)).baselineOffset(-4)
  }

  /// 单独显示（回应等）：图或文字。
  @MainActor static func view(_ id: String, size: CGFloat = 16) -> Text {
    if image(id, size: size) == nil, Int(id).map({ $0 <= 0x2000 && names[$0] == nil }) ?? false {
      return Text(Image(systemName: "face.smiling"))  // 本地没有的新表情：通用图标
    }
    return inline(id, size: size)
  }

  /// 表情面板里可选的：本地有图、QQ 里没藏起来的（按编号排）。
  @MainActor static let pickable: [(id: Int, name: String)] = names.keys.sorted()
    .filter { Bundle.main.url(forResource: "s\($0)", withExtension: "png", subdirectory: "QQFaces") != nil }
    .map { ($0, names[$0]!) }

  @MainActor private static var cache: [String: UIImage] = [:]

  @MainActor static func image(_ id: String, size: CGFloat) -> UIImage? {
    let key = "\(id)@\(size)"
    if let hit = cache[key] { return hit }
    guard Int(id) != nil,
          let url = Bundle.main.url(forResource: "s\(id)", withExtension: "png", subdirectory: "QQFaces"),
          let source = UIImage(contentsOfFile: url.path)
    else { return nil }
    let scaled = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
      source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    cache[key] = scaled
    return scaled
  }
}

/// 卡片消息（小程序、分享链接等）：从 JSON 里挑一句能看的。
enum CardText {
  static func from(json: String, app: String) -> String {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return "[卡片消息]"
    }
    if let prompt = obj["prompt"] as? String, !prompt.isEmpty { return prompt }
    if let meta = obj["meta"] as? [String: Any] {
      for v in meta.values {
        if let d = v as? [String: Any], let title = (d["title"] ?? d["desc"]) as? String, !title.isEmpty { return title }
      }
    }
    return "[卡片消息] \(app)"
  }
}

/// 服务事件的一句话描述。
enum EventText {
  @MainActor static func describe(_ e: Qqbridge_V1_ChatEvent, context: MessageContext) -> String {
    let data = (try? JSONSerialization.jsonObject(with: Data(e.dataJson.utf8)) as? [String: Any]) ?? [:]
    let actor = e.actorID == 0 ? "" : context.name(of: e.actorID)
    let target = e.targetID == 0 ? "" : context.name(of: e.targetID)
    switch e.kind {
    case "member_join": return "\(target.isEmpty ? actor : target) 加入了群聊"
    case "member_leave": return "\(target.isEmpty ? actor : target) 离开了群聊"
    case "admin_set": return "\(target) 成为管理员"
    case "admin_unset": return "\(target) 不再是管理员"
    case "mute": return target.isEmpty ? "\(actor) 开启了全员禁言" : "\(target) 被禁言"
    case "unmute": return target.isEmpty ? "\(actor) 关闭了全员禁言" : "\(target) 被解除禁言"
    case "card_change": return "\(target) 修改了群名片"
    case "title": return "\(target) 获得了头衔 \(data["title"] as? String ?? "")"
    case "group_name": return "\(actor) 修改群名为 \(data["name"] as? String ?? "")"
    case "essence_add": return "\(actor) 设置了一条精华消息"
    case "essence_remove": return "\(actor) 移除了一条精华消息"
    case "poke": return "\(actor) 戳了戳 \(target)"
    case "friend_add": return "你们已成为好友"
    case "group_file": return "\(actor) 上传了文件 \(data["name"] as? String ?? "")"
    case "call":
      let video = (data["media"] as? String) == "video"
      if (data["result"] as? String) == "answered" {
        return "\(video ? "视频" : "语音")通话 \(Format.duration(data["durationSec"] as? Int ?? 0))"
      }
      return "未接\(video ? "视频" : "语音")通话"
    case "gray_tip": return data["text"] as? String ?? "系统消息"
    default: return "[\(e.kind)]"
    }
  }
}

extension Format {
  static func chatTime(_ unix: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unix))
    if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale)) }
    return date.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
  }

  static func duration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
