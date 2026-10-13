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
  /// 跳转到的那条消息短暂高亮。
  let highlight: MessageHighlight
  /// 名字、头像、被回复消息的内存缓存：滚动时不在主线程查数据库。
  let lookup: ChatLookup
  let bubbleFrames: BubbleFrames

  /// 显示名：我 > 群名片 / 昵称 > 联系人备注 / 昵称 > 号码。
  @MainActor
  func name(of userId: Int64) -> String {
    if userId == selfUin { return "我" }
    if isGroup, let n = members.displayName(userId) { return n }
    return lookup.userName(userId) ?? String(userId)
  }

  /// @ 徽章里的小头像：内存里有就用；没有时先只显示名字，头像加载好后（imageTick 变了）重画。
  @MainActor
  func avatarImage(_ userId: Int64) -> UIImage? {
    _ = avatars.imageTick
    guard let sha = avatars.sha256[userId] ?? lookup.avatar(userId), let full = ImageMemoryCache.shared.get(sha) else { return nil }
    return MentionAvatar.circle(full, key: sha)
  }

  /// 能不能撤回（QQ 的规则，最终以 QQ 的结果为准）：
  /// - 自己的消息：2 分钟内；群主撤回自己的不限时间。
  /// - 群主：管理员和成员的消息，不限时间。
  /// - 管理员：普通成员的消息，不限时间。
  /// 普通撤回（自己 2 分钟内的消息）和群管理撤回（用群主 / 管理员权限）分开显示。
  enum RecallKind {
    case normal
    case owner
    case admin
  }

  @MainActor
  func recallKind(_ m: Qqbridge_V1_Message) -> RecallKind? {
    guard m.state != .recalled else { return nil }
    let mine = isGroup ? role(of: selfUin) : "member"
    if m.senderID == selfUin {
      if Date().timeIntervalSince1970 - Double(m.time) < 120 { return .normal }
      return mine == "owner" ? .owner : nil
    }
    guard isGroup else { return nil }
    switch mine {
    case "owner": return role(of: m.senderID) != "owner" ? .owner : nil
    case "admin": return role(of: m.senderID) == "member" ? .admin : nil
    default: return nil
    }
  }

  @MainActor
  private func role(of userId: Int64) -> String {
    members.byId[userId]?.role ?? "member"
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
        Notice(text: EventText.describe(e, context: context), people: EventText.people(e, context: context)) { context.actions.showProfile($0) }
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
    .coordinateSpace(.named(MessageRow.space))
    // 高亮的淡入淡出只作用在底色上：以前整行挂着这个动画，跳转时可见的行的排版变化也跟着做动画，
    // 复用的格子会从上一条消息的位置滑过来（气泡错位、叠在一起、看不见）。
    .background {
      Color.accentColor.opacity(isHighlighted ? 0.15 : 0).padding(.horizontal, -12)
        .animation(.easeOut(duration: 0.4), value: isHighlighted)
    }
  }

  private var isHighlighted: Bool {
    if case .message(let m) = item { return context.highlight.seq == m.seq }
    return false
  }

  /// 行内坐标系的名字（气泡位置用）。
  static let space = "messageRow"

  /// 和上一条隔了 5 分钟以上才显示时间。
  private var showsTime: Bool {
    guard let previous else { return true }
    return item.time - previous.time > 300
  }

  /// 群里，连续同一个人发的只在第一条显示名字和头像。
  private func showsSender(_ m: Qqbridge_V1_Message) -> Bool {
    guard context.isGroup, m.senderID != context.selfUin else { return false }
    if showsTime { return true }
    if case .message(let p)? = previous, p.senderID == m.senderID { return false }
    return true
  }
}

struct Notice: View {
  let text: String
  /// 文字里出现的人（QQ 号 → 显示名）：名字点一下打开资料卡。
  var people: [(id: Int64, name: String)] = []
  var onPerson: (Int64) -> Void = { _ in }

  var body: some View {
    Text(attributed)
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "qqbridge-user", let id = Int64(url.host() ?? "") else { return .systemAction }
        onPerson(id)
        return .handled
      })
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(.quaternary.opacity(0.5), in: Capsule())
  }

  /// 把人名标成链接（同一个名字出现两次时按顺序各标一次）。
  private var attributed: AttributedString {
    var out = AttributedString(text)
    var searchFrom = out.startIndex
    for p in people where !p.name.isEmpty {
      guard let range = out[searchFrom...].range(of: p.name) else { continue }
      out[range].link = URL(string: "qqbridge-user://\(p.id)")
      out[range].foregroundColor = .accentColor
      searchFrom = range.upperBound
    }
    return out
  }
}

struct MessageBubbleRow: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext

  let showsSender: Bool

  private var outgoing: Bool { message.senderID == context.selfUin }
  private var recalled: Bool { message.state == .recalled }

  /// 自己撤回的就是"已撤回"；被别人（群主、管理员）撤回的写上是谁。
  private var recalledText: String {
    guard message.recalledBy != 0, message.recalledBy != message.senderID else { return "已撤回" }
    return message.recalledBy == context.selfUin ? "被你撤回" : "被\(context.name(of: message.recalledBy))撤回"
  }

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
              if m.isRobot { RoleTag(text: "机器人", color: .blue) }
              if !m.title.isEmpty { RoleTag(text: m.title, color: .purple) }
            }
          }
        }
        // 撤回的消息照样显示，旁边标"已撤回"（服务端保留了原内容）。
        HStack(alignment: .bottom, spacing: 6) {
          if recalled, outgoing { RecalledTag(text: recalledText) }
          MessageContent(message: message, context: context, outgoing: outgoing)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MessageRow.space)) } action: { context.bubbleFrames.set(message.seq, $0) }
            // 动图表情是 UIKit 视图、透明的地方不算点中：整块都算，长按才弹得出菜单。
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
            // 按在 @ 徽章上的长按归徽章（打开资料卡），这时气泡不弹菜单。
            .contextMenu { if MentionPress.shared.seq != message.seq { menu } }
          if recalled, !outgoing { RecalledTag(text: recalledText) }
        }
        if !message.reactions.isEmpty { Reactions(message: message, context: context) }
      }
      if !outgoing { Spacer(minLength: 48) }
    }
  }

  static func isSticker(_ m: Qqbridge_V1_Message) -> Bool {
    m.segments.contains { seg in
      switch seg.kind {
      case .image(let i): i.sticker
      case .marketFace: true
      default: false
      }
    }
  }

  /// 能加到"我的表情"的图片 / 表情（一条消息里的第一个）。
  static func stickerable(_ m: Qqbridge_V1_Message) -> Qqbridge_V1_MediaInfo? {
    for seg in m.segments {
      switch seg.kind {
      case .image(let i): return i.media
      case .marketFace(let f) where f.hasMedia: return f.media
      default: continue
      }
    }
    return nil
  }

  @ViewBuilder private var menu: some View {
    if !recalled {
      Button("回复", systemImage: "arrowshape.turn.up.left") { context.actions.reply(message) }
      Button("转发", systemImage: "arrowshape.turn.up.right") { context.actions.forward(message) }
    }
    Button("多选", systemImage: "checkmark.circle") { context.selection.start(with: message.seq) }
    if let image = Self.stickerable(message) {
      // 复制图片 / 表情：剪贴板里放图片本身（别的 App 也能粘贴）+ 服务端的 sha256（粘到本 App 别的会话不用重新上传）。
      Button("复制", systemImage: "doc.on.doc") { context.actions.copyMedia(image, Self.isSticker(message)) }
    } else if !message.text.isEmpty, !message.segments.contains(where: { if case .record = $0.kind { true } else { false } }) {
      // 语音消息的 text 只是「[语音]」，不给复制。
      Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
    }
    if let image = Self.stickerable(message) {
      Button("添加到我的表情", systemImage: "face.smiling.inverse") { context.actions.addSticker(image, message.seq) }
    }
    if !recalled, message.segments.contains(where: { if case .record = $0.kind { true } else { false } }) {
      // 语音转文字：用 QQ 自己的识别。
      if case .text = VoiceTranscripts.shared.state(chatId: context.chatId, seq: message.seq) {
        Button("收起文字", systemImage: "text.badge.minus") { VoiceTranscripts.shared.hide(chatId: context.chatId, seq: message.seq) }
      } else {
        Button("转文字", systemImage: "text.bubble") { VoiceTranscripts.shared.transcribe(chatId: context.chatId, seq: message.seq, session: context.session) }
      }
    }
    if context.isGroup, !outgoing {
      Button("@\(context.name(of: message.senderID))", systemImage: "at") { context.actions.mention(message.senderID) }
    }
    if context.isGroup, !recalled {
      Menu("回应", systemImage: "face.smiling") {
        ForEach(ReactionRecents.list, id: \.self) { id in
          Button {
            ReactionRecents.use(id)
            context.actions.react(message, id)
          } label: {
            if let image = ReactionLabel.icon(id, size: 22) {
              Label { Text(ReactionLabel.name(id)) } icon: { Image(uiImage: image) }
            } else {
              Text(ReactionLabel.name(id))
            }
          }
        }
        Divider()
        Button("更多表情…", systemImage: "ellipsis") { context.actions.pickReaction(message) }
      }
    }
    switch context.recallKind(message) {
    case .normal:
      Button("撤回", systemImage: "arrow.uturn.backward", role: .destructive) { context.actions.recall(message) }
    case .owner:
      Button("以群主身份撤回", systemImage: "crown", role: .destructive) { context.actions.recall(message) }
    case .admin:
      Button("以管理员身份撤回", systemImage: "shield.lefthalf.filled", role: .destructive) { context.actions.recall(message) }
    case nil:
      EmptyView()
    }
  }
}

/// 群友头像：点开看资料，长按 @ 他。头像按需向服务端要（显示到谁要谁的）。
struct SenderAvatar: View {
  let userId: Int64
  let context: MessageContext

  var body: some View {
    let name = context.name(of: userId)
    let sha = context.avatars.sha256[userId] ?? context.lookup.avatar(userId)
    AvatarView(sha256: sha, title: name, seed: userId, size: 34)
      .onAppear { context.avatars.want(userId, session: context.session) }
      .onTapGesture { context.actions.showProfile(userId) }
      .onLongPressGesture(minimumDuration: 0.4) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        context.actions.mention(userId)
      }
  }
}

/// 消息旁边的"已撤回"标记。
struct RecalledTag: View {
  let text: String
  var body: some View {
    Label(text, systemImage: "arrow.uturn.backward")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)
      .fixedSize()
      .padding(.bottom, 2)
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
    let time = Format.clockTime(message.time)
    let place = TimePlacement.of(blocks.last, bare: bare)
    VStack(alignment: .leading, spacing: 6) {
      ForEach(blocks.indices, id: \.self) { i in
        // 发送时间放在气泡右下角：最后是文字时在最后一行末尾留出时间的位置（和 Telegram 一样，放得下就同一行）。
        BlockView(block: blocks[i], context: context, outgoing: outgoing, message: message, timeReserve: place == .inline && i == blocks.count - 1 ? time : nil)
      }
    }
    // 单独一行时：底下留出一行的高度（不占宽度，气泡不会因此被撑宽），时间画在右下角。
    .padding(.bottom, place == .row ? 12 : 0)
    .padding(bare ? 0 : 10)
    .background {
      if !bare {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(outgoing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.secondarySystemBackground)))
      }
    }
    .overlay(alignment: .bottomTrailing) {
      switch place {
      case .inline, .row:
        Text(time).font(.caption2.monospacedDigit()).opacity(0.7).padding(.trailing, 10).padding(.bottom, 8)
      case .pill:
        // 图片、视频、表情上：半透明底的小胶囊。
        Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.white)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(.black.opacity(0.45), in: Capsule())
          .padding(bare ? 4 : 16)
      }
    }
    .foregroundStyle(outgoing && !bare ? Color.white : Color.primary)
  }
}

/// 气泡里的发送时间放哪：文字末尾（inline）、压在图片上（pill）、单独一行（row）。
enum TimePlacement {
  case inline, pill, row

  static func of(_ last: Block?, bare: Bool) -> TimePlacement {
    if bare { return .pill }
    switch last {
    case .text(let runs): return Inline.jumboFaces(runs) == nil ? .inline : .pill
    // 卡片底下常有「在浏览器中打开」等文字：时间另起一行，不压在卡片上。
    case .image, .video, .sticker: return .pill
    default: return .row
    }
  }
}

/// 排版块：相邻的文字、@、表情合成一段富文本，其余各成一块。
enum Block {
  case text([Inline])
  case reply(Int64)
  case image(Qqbridge_V1_ImageSegment)
  /// size：表情的原始尺寸（不知道时为 nil，按正方形显示）。
  case sticker(media: Qqbridge_V1_MediaInfo, summary: String, size: CGSize?)
  case record(Qqbridge_V1_RecordSegment)
  case video(Qqbridge_V1_VideoSegment)
  case file(Qqbridge_V1_FileSegment)
  case forward(Qqbridge_V1_ForwardSegment)
  case card(String)
  /// 小程序 / 分享卡片（哔哩哔哩、新闻、音乐……）：能打开的点开用浏览器。
  case app(AppCard)
  /// 机器人发的 markdown（带图片）。
  case markdown(String)
  /// 机器人消息下面的按钮。
  case keyboard([[BotButton]])

  var isBare: Bool {
    switch self {
    case .sticker: true
    case .image(let i): i.sticker
    case .text(let runs): Inline.jumboFaces(runs) != nil
    default: false
    }
  }

  static func size(_ width: UInt32, _ height: UInt32, _ media: Qqbridge_V1_MediaInfo) -> CGSize? {
    if width > 0, height > 0 { return CGSize(width: Int(width), height: Int(height)) }
    if media.width > 0, media.height > 0 { return CGSize(width: Int(media.width), height: Int(media.height)) }
    return nil
  }

  /// 表情显示的大小：按原始比例放进 140×140 的框里。先定好大小，不等图片加载——
  /// 聊天列表的格子按第一次排版时的大小定高，图片加载完不会再撑开（否则第一次进会话时表情会被压得很小）。
  static func stickerFrame(_ size: CGSize?) -> CGSize {
    let box: CGFloat = 140
    guard let size, size.width > 0, size.height > 0 else { return CGSize(width: box, height: box) }
    let scale = box / max(size.width, size.height)
    return CGSize(width: max(40, size.width * scale), height: max(40, size.height * scale))
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
    // 机器人的 markdown 消息后面常跟一份纯文字版（给不支持 markdown 的客户端看）：有 markdown 时不再显示文字和 @。
    var keyboard: [[BotButton]]?
    let hasMarkdown = segments.contains { if case .markdown = $0.kind { true } else { false } }
    for seg in segments {
      if hasMarkdown {
        switch seg.kind {
        case .text, .mention, .mentionAll: continue
        default: break
        }
      }
      switch seg.kind {
      case .text(let t): text += Linkify.attributed(t.text)
      case .mention(let m):
        // 真正的 @（带了 QQ 号的）显示成徽章 + 头像；手打的 "@某某" 只是普通文字。
        cut()
        runs.append(.mention(m.userID, name: m.name.isEmpty ? context.name(of: m.userID) : m.name, avatar: context.avatarImage(m.userID)))
      case .mentionAll:
        var a = AttributedString("@全体成员 ")
        a.font = .body.bold()
        text += a
      case .face(let f): cut(); runs.append(.face(f.faceID, name: f.name, large: f.isLarge))
      case .reply(let r): out.insert(.reply(r.seq), at: 0)
      case .image(let i):
        flush()
        out.append(i.sticker ? .sticker(media: i.media, summary: i.summary, size: Block.size(i.width, i.height, i.media)) : .image(i))
      case .record(let r): flush(); out.append(.record(r))
      case .video(let v): flush(); out.append(.video(v))
      case .file(let f): flush(); out.append(.file(f))
      case .forward(let f): flush(); out.append(.forward(f))
      case .marketFace(let f):
        flush()
        if f.hasMedia, !f.media.sha256.isEmpty {
          out.append(.sticker(media: f.media, summary: f.summary, size: Block.size(0, 0, f.media)))
        } else {
          out.append(.text([.text(AttributedString(f.summary.isEmpty ? "[表情]" : f.summary))]))
        }
      case .lightApp(let a):
        flush()
        if let card = AppCard.parse(json: a.json, app: a.appName) { out.append(.app(card)) } else { out.append(.card(CardText.from(json: a.json, app: a.appName))) }
      case .xml: flush(); out.append(.card("[卡片消息]"))
      case .markdown(let m): flush(); out.append(.markdown(m.content))
      case .unknown(let u):
        switch u.original {
        case "keyboard":
          // 机器人按钮：放在消息最下面。
          let rows = BotButton.parse(u.dataJson)
          if !rows.isEmpty { keyboard = rows }
        case "dice": text += AttributedString("[骰子]")
        case "rps": text += AttributedString("[猜拳]")
        default: text += AttributedString("[暂不支持的消息]")
        }
      case .none: break
      }
    }
    flush()
    if let keyboard { out.append(.keyboard(keyboard)) }
    return out
  }
}

struct BlockView: View {
  let block: Block
  let context: MessageContext
  let outgoing: Bool
  var message: Qqbridge_V1_Message? = nil
  /// 文字的最后一行末尾留出这么宽的位置（放发送时间）。
  var timeReserve: String? = nil

  var body: some View {
    switch block {
    case .text(let runs):
      if let faces = Inline.jumboFaces(runs), faces.count == 1, faces[0].large {
        // 超级表情（QQ 里单独发的会动的大表情）：播 QQ 的动画。
        SuperFaceView(id: faces[0].id, name: faces[0].name)
      } else if let faces = Inline.jumboFaces(runs) {
        // 只有 1–3 个 QQ 表情：放大显示，不要气泡（和 Telegram 的单 emoji 消息一样）。
        let size: CGFloat = faces.count == 1 ? 72 : 52
        HStack(spacing: 4) {
          ForEach(faces.indices, id: \.self) { i in QQFace.inline(faces[i].id, name: faces[i].name, size: size) }
        }
      } else {
        MentionText(runs: runs, context: context, outgoing: outgoing, seq: message?.seq ?? 0, reserve: timeReserve)

      }
    case .reply(let seq):
      ReplyQuote(seq: seq, context: context, outgoing: outgoing)
    case .image(let i):
      MediaThumb(media: i.media, width: i.width, height: i.height, chatId: context.chatId, onNeedThumb: { requestMedia(i.media) })
        .onTapGesture { context.actions.openMedia(MediaTarget(kind: .image, media: i.media, chatId: context.chatId, seq: message?.seq ?? 0)) }
    case .sticker(let media, let summary, let size):
      // 表情用原图（会动）；原图还没有时先显示以前的缩略图，不常用会话里显示到时才向服务端要原图。
      let sha = media.state == .stored && !media.sha256.isEmpty ? media.sha256 : (media.thumbSha256.isEmpty ? nil : media.thumbSha256)
      StickerImage(sha256: sha, chatId: context.chatId, summary: summary)
      .frame(width: Block.stickerFrame(size).width, height: Block.stickerFrame(size).height)
      .onAppear { if media.state == .onDemand { requestMedia(media) } }
    case .record(let r):
      VStack(alignment: .leading, spacing: 0) {
        let isPlaying = context.voice.isPlaying(r)
        VoiceBubble(
          record: r,
          playing: isPlaying,
          progress: isPlaying ? context.voice.progress : 0,
          remaining: isPlaying ? max(0, Int((context.voice.duration * (1 - context.voice.progress)).rounded(.up))) : nil,
          onWaveFrame: { context.voice.waveFrame = $0 }
        )
        .contentShape(Rectangle())
        .onTapGesture { context.actions.playVoice(r) }
        if let message { VoiceTranscriptView(chatId: context.chatId, seq: message.seq, outgoing: outgoing) }
      }
    case .video(let v):
      // 没有封面时向服务端要 QQ 自带的封面（几十 KB，不下视频本身）。
      MediaThumb(media: v.media, width: v.width, height: v.height, chatId: context.chatId, onNeedThumb: { requestMedia(v.media) }, isVideo: true)
        .onTapGesture {
          // 按需的视频也直接打开播放器：播放器向服务端要原件，等服务端推「下好了」后自动播放。
          // （不能走 requestMedia：那只要视频封面，而封面一般已经有了，点了没反应。）
          context.actions.openMedia(MediaTarget(kind: .video, media: v.media, chatId: context.chatId, seq: message?.seq ?? 0))
        }
        .overlay {
          Image(systemName: v.media.state == .onDemand ? "arrow.down.circle.fill" : v.media.state == .pending ? "hourglass.circle.fill" : "play.circle.fill")
            .font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
        }
        // 时长放左上角（右下角是发送时间）。
        .overlay(alignment: .topLeading) {
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
    case .app(let card):
      AppCardView(card: card, outgoing: outgoing) { context.actions.openAlbum($0) }
    case .markdown(let content):
      MarkdownBlock(content: content, outgoing: outgoing)
    case .keyboard(let rows):
      BotKeyboard(rows: rows, outgoing: outgoing) { button in
        if let message { context.actions.botButton(button, message.senderID) }
      }
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
  /// 视频：没有封面时不拿视频原件当缩略图（那是视频文件）。
  var isVideo = false
  @Environment(\.session) private var session
  @State private var localOriginal = false

  /// 显示哪张：手机上已有原图就显示原图（缩小解码），否则 QQ 缩略图；都没有时服务端有原图就下原图。
  private var displaySha: String? {
    if localOriginal, !isVideo { return media.sha256 }
    if !media.thumbSha256.isEmpty { return media.thumbSha256 }
    if !isVideo, media.state == .stored, !media.sha256.isEmpty { return media.sha256 }
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
    .onAppear { if media.thumbSha256.isEmpty, isVideo || media.state != .stored { onNeedThumb?() } }
  }
}

/// 语音：波形 + 时长，点一下播放 / 停止。
/// 语音气泡：波形 + 时长。播放时气泡变大，听过的部分波形填满颜色，白线标出播放位置，拖白线可以调进度。
struct VoiceBubble: View {
  let record: Qqbridge_V1_RecordSegment
  var playing = false
  /// 播放进度 0…1（没在播时不用）。
  var progress: Double = 0
  /// 剩余秒数（播放时显示）。
  var remaining: Int? = nil
  /// 播放时波形在窗口里的位置。
  var onWaveFrame: ((CGRect) -> Void)? = nil

  var body: some View {
    let bars = Array(record.media.waveform)
    let seconds = Int(record.durationSec)
    let width = CGFloat(min(160, 60 + seconds * 4)) + (playing ? 40 : 0)
    let barHeight: CGFloat = playing ? 28 : 18
    HStack(spacing: 8) {
      Image(systemName: playing ? "stop.fill" : "play.fill")
        .font(playing ? .title3 : .body)
      ZStack(alignment: .leading) {
        waveform(bars, height: barHeight, width: width).opacity(playing ? 0.35 : 1)
        if playing {
          // 听过的部分：同一份波形，按进度裁出左边一截，填满颜色。
          waveform(bars, height: barHeight, width: width)
            .mask(alignment: .leading) { Rectangle().frame(width: width * progress) }
          // 白线：播放位置，可以拖。
          Capsule()
            .fill(.white)
            .frame(width: 3, height: barHeight + 10)
            .shadow(color: .black.opacity(0.35), radius: 1.5)
            .offset(x: max(0, min(width - 3, width * progress - 1.5)))
        }
      }
      .frame(width: width, height: barHeight + 10, alignment: .leading)
      // 拖白线由聊天列表的拖动手势处理（SwiftUI 的拖动抢不过系统的返回手势）：这里只报告波形的位置。
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { if playing { onWaveFrame?($0) } }
      Text("\(playing ? (remaining ?? seconds) : seconds)″").font(.caption.monospacedDigit())
    }
    .padding(.vertical, playing ? 4 : 0)
    .animation(.spring(duration: 0.3), value: playing)
  }

  private func waveform(_ bars: [UInt8], height: CGFloat, width: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(0..<max(bars.count, 1), id: \.self) { i in
        let v = bars.isEmpty ? 0.3 : CGFloat(bars[i]) / 255
        Capsule().frame(width: 2, height: 4 + (height - 4) * v)
      }
    }
    .frame(width: width, alignment: .leading)
    .clipped()
  }
}

struct ReplyQuote: View {
  let seq: Int64
  let context: MessageContext
  let outgoing: Bool
  @Environment(\.session) private var session
  @State private var original: Qqbridge_V1_Message?
  @State private var missing = false
  /// 点了之后正在拉原消息 / 往上翻找它。
  @State private var jumping = false

  init(seq: Int64, context: MessageContext, outgoing: Bool) {
    self.seq = seq
    self.context = context
    self.outgoing = outgoing
    // 被回复的消息已经在列表里就直接用：不先显示"…"再撑开（会让列表跳一下）。
    _original = State(initialValue: context.lookup.message(seq))
  }

  /// 订阅到的本地这条消息（最新）；还没订阅到时先用列表里的。
  private var shown: Qqbridge_V1_Message? { original ?? context.lookup.message(seq) }

  var body: some View {
    HStack(spacing: 6) {
      Rectangle().frame(width: 3).opacity(0.6)
      // 被回复的是图片、表情、视频：按缩略图的比例缩小显示（还没有缩略图的先显示图标，并向服务端要）。
      if let shown, let media = Self.media(shown) {
        let size = Self.thumbSize(media.info)
        CachedImage(sha256: Self.thumbnail(media), chatId: context.chatId, maxPixel: 160) {
          ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            Image(systemName: media.kind == .video ? "video" : "photo").font(.caption).foregroundStyle(.secondary)
          }
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
          if media.kind == .video { Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white).shadow(radius: 2) }
        }
        .task(id: shown.seq) {
          // 没有缩略图（视频是封面）：请服务端下载一次；下好后经同步写进本地库，下面的订阅会自动刷新。
          if Self.thumbnail(media) == nil {
            context.requester.want(chatId: context.chatId, seq: shown.seq, ord: media.info.ord, session: context.session)
          }
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        if let shown {
          HStack(spacing: 6) {
            Text(context.name(of: shown.senderID)).font(.caption.bold()).lineLimit(1)
            Text(Format.messageTime(shown.time)).font(.caption2).opacity(0.7)
          }
          Text(Format.preview(shown)).font(.caption).lineLimit(2)
        } else if jumping {
          Text("正在拉取原消息…").font(.caption)
        } else {
          Text(missing ? "原消息暂时拿不到，点一下重试" : "…").font(.caption)
        }
      }
      .opacity(0.85)
      if jumping {
        Spacer(minLength: 0)
        ProgressView().controlSize(.mini)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    // 点引用跳到原消息：本地没有就先拉回来，再往上翻到它；期间显示加载中。
    .onTapGesture {
      guard !jumping else { return }
      jumping = true
      Task {
        defer { jumping = false }
        if shown == nil {
          missing = false
          await load()
          if shown == nil { return }
        }
        _ = await context.actions.jumpTo(seq)
      }
    }
    .task(id: seq) {
      // 订阅本地库里的原消息：缩略图、封面下好了，撤回、回应变了都会推过来。本地没有时向服务端要一次（拉回来会写进本地库，订阅随即推到）。
      var asked = false
      do {
        for try await m in context.store.observeMessage(chatId: context.chatId, seq: seq) {
          if let m {
            original = m
            missing = false
          } else if !asked {
            asked = true
            if await session?.sync.fetchMessage(chatId: context.chatId, seq: seq) == nil { missing = true }
          }
        }
      } catch {}
    }
  }

  /// 缩略图大小：高 40，宽按比例（16…80）。不知道比例时是正方形。
  static func thumbSize(_ media: Qqbridge_V1_MediaInfo) -> CGSize {
    let h: CGFloat = 40
    guard media.width > 0, media.height > 0 else { return CGSize(width: h, height: h) }
    let w = h * CGFloat(media.width) / CGFloat(media.height)
    return CGSize(width: min(80, max(16, w)), height: h)
  }

  struct QuotedMedia {
    enum Kind { case image, video }
    let kind: Kind
    let info: Qqbridge_V1_MediaInfo
  }

  /// 被回复消息里的第一张图片 / 表情 / 视频。
  static func media(_ m: Qqbridge_V1_Message) -> QuotedMedia? {
    for seg in m.segments {
      switch seg.kind {
      case .image(let i): return QuotedMedia(kind: .image, info: i.media)
      case .video(let v): return QuotedMedia(kind: .video, info: v.media)
      case .marketFace(let f) where f.hasMedia: return QuotedMedia(kind: .image, info: f.media)
      default: continue
      }
    }
    return nil
  }

  /// 缩略图：QQ 缩略图 / 预览图 / 已下载的原图。
  static func thumbnail(_ m: QuotedMedia) -> String? {
    let media = m.info
    // 视频的原件是视频文件，不能当图片：只用封面。
    let original = m.kind == .image && media.state == .stored ? media.sha256 : ""
    for sha in [media.thumbSha256, media.previewSha256, original] where !sha.isEmpty { return sha }
    return nil
  }

  private func load() async {
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

struct Reactions: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext
  /// 长按某个回应：看都有谁点了。
  @State private var showing: String?

  var body: some View {
    HStack(spacing: 4) {
      ForEach(message.reactions, id: \.emojiID) { r in
        HStack(spacing: 2) {
          QQFace.view(r.emojiID)
          Text("\(r.count)").monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(r.me ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
        .contentShape(Capsule())
        // 点一下：加上 / 取消自己的回应；长按：看都有谁点了（只有群聊有回应）。
        .onTapGesture { if context.isGroup { context.actions.react(message, r.emojiID) } }
        .onLongPressGesture(minimumDuration: 0.35) { if context.isGroup { showing = r.emojiID } }
        .accessibilityAddTraits(.isButton)
      }
    }
    .sheet(item: Binding(get: { showing.map(ReactionPick.init) }, set: { showing = $0?.id })) { pick in
      ReactionUsersSheet(message: message, context: context, selected: pick.id)
        .presentationDetents([.medium, .large])
    }
  }
}

struct ReactionPick: Identifiable {
  let id: String
}

/// 点了回应的人：上面一排切换是哪个表情，下面是点了的人（头像 + 群名片）。点人看资料。
struct ReactionUsersSheet: View {
  let message: Qqbridge_V1_Message
  let context: MessageContext
  @State var selected: String
  @Environment(\.dismiss) private var dismiss
  @State private var users: [String: [Qqbridge_V1_ReactionUser]] = [:]
  @State private var errors: [String: String] = [:]

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(message.reactions, id: \.emojiID) { r in
              Button { selected = r.emojiID } label: {
                HStack(spacing: 3) {
                  QQFace.view(r.emojiID, size: 20)
                  Text("\(r.count)").monospacedDigit()
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected == r.emojiID ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }
        List {
          if let list = users[selected] {
            ForEach(list, id: \.userID) { u in
              Button {
                dismiss()
                context.actions.showProfile(u.userID)
              } label: {
                HStack(spacing: 12) {
                  AvatarView(sha256: context.avatars.sha256[u.userID], title: displayName(u), seed: u.userID, size: 36)
                  Text(displayName(u)).foregroundStyle(.primary)
                  Spacer()
                  if u.userID == context.selfUin { Text("我").font(.caption).foregroundStyle(.secondary) }
                }
              }
              .onAppear { context.avatars.want(u.userID, session: context.session) }
            }
          } else if let error = errors[selected] {
            Text(error).foregroundStyle(.secondary)
          } else {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
          }
        }
        .listStyle(.plain)
      }
      .navigationTitle(ReactionLabel.name(selected))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
      .task(id: selected) { await load(selected) }
    }
  }

  private func displayName(_ u: Qqbridge_V1_ReactionUser) -> String {
    if u.userID == context.selfUin { return context.name(of: u.userID) }
    if let n = context.members.displayName(u.userID) { return n }
    return u.name.isEmpty ? String(u.userID) : u.name
  }

  private func load(_ emoji: String) async {
    guard users[emoji] == nil else { return }
    var req = Qqbridge_V1_ListReactionUsersRequest()
    req.chatID = context.chatId
    req.seq = message.seq
    req.emojiID = emoji
    do {
      users[emoji] = try await context.session.api.messages.listReactionUsers(request: req, headers: context.session.api.headers).get().users
    } catch {
      errors[emoji] = LoadState.describe(error)
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
      if let image = entry.segments.compactMap({ seg -> Qqbridge_V1_OutgoingMedia? in if case .image(let i) = seg.kind { i } else { nil } }).first {
        // 图片、表情：直接显示（已经在服务端了）。
        CachedImage(sha256: image.sha256, maxPixel: 420, animated: image.sticker) {
          RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 140, height: 140)
        }
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: image.sticker ? 140 : 220, maxHeight: image.sticker ? 140 : 280)
        .clipShape(RoundedRectangle(cornerRadius: image.sticker ? 0 : 14, style: .continuous))
        .opacity(0.8)
      } else {
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
  case mention(Int64, name: String, avatar: UIImage?)

  /// 整段只有 1–3 个 QQ 表情（可夹空白）时返回它们，用来放大显示。
  static func jumboFaces(_ runs: [Inline]) -> [(id: String, name: String, large: Bool)]? {
    var faces: [(id: String, name: String, large: Bool)] = []
    for run in runs {
      switch run {
      case .face(let id, let name, let large): faces.append((id, name, large))
      case .mention: return nil
      case .text(let a): if !String(a.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
      }
    }
    return (1...3).contains(faces.count) ? faces : nil
  }

  @MainActor static func compose(_ runs: [Inline], outgoing: Bool = false) -> Text {
    runs.reduce(Text(verbatim: "")) { acc, run in
      switch run {
      case .text(let a): Text("\(acc)\(Text(a))")
      case .face(let id, let name, let large): Text("\(acc)\(QQFace.inline(id, name: name, size: large ? 64 : 20))")
      case .mention(let userId, let name, let avatar): Text("\(acc)\(mentionBadge(name, avatar: avatar, outgoing: outgoing, userId: userId))")
      }
    }
  }

  /// @ 徽章：淡色底 + 小头像 + 名字（自己发的蓝色气泡里用白色）。
  /// @ 徽章：画成一张圆角胶囊图（小头像 + @名字）插进文字里，和正文基线对齐。
  @MainActor static func mentionBadge(_ name: String, avatar: UIImage?, outgoing: Bool, userId: Int64 = 0) -> Text {
    let badge = MentionBadgeRenderer.render(name: name, avatar: avatar, outgoing: outgoing)
    return Text(Image(uiImage: badge.image)).baselineOffset(badge.baselineOffset).customAttribute(MentionTag(userId: userId)) + Text(" ")
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
  @MainActor static let pickable: [(id: Int, name: String)] = infos.keys.sorted()
    .filter { !(infos[$0]?.hidden ?? true) && Bundle.main.url(forResource: "s\($0)", withExtension: "png", subdirectory: "QQFaces") != nil }
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
        if let d = v as? [String: Any], let title = (d["title"] ?? d["desc"]) as? String, !title.isEmpty { return "[卡片] \(title)" }
      }
    }
    return "[卡片]"
  }
}

/// 服务事件的一句话描述。
enum EventText {
  /// 灰条文字里按出现顺序会提到的人（用来把名字标成可点的链接）。
  @MainActor static func people(_ e: Qqbridge_V1_ChatEvent, context: MessageContext) -> [(id: Int64, name: String)] {
    let actor = e.actorID == 0 ? nil : (id: e.actorID, name: context.name(of: e.actorID))
    let target = e.targetID == 0 ? nil : (id: e.targetID, name: context.name(of: e.targetID))
    let data = (try? JSONSerialization.jsonObject(with: Data(e.dataJson.utf8)) as? [String: Any]) ?? [:]
    // 文字里目标在前的几种（「B 被 A 禁言」「B 被 A 移出了群聊」）。
    let targetFirst = (e.kind == "mute" || e.kind == "unmute") || (e.kind == "member_leave" && ["kick", "kick_me"].contains(data["how"] as? String ?? ""))
    let ordered = targetFirst ? [target, actor] : [actor, target]
    return ordered.compactMap { $0 }
  }


  @MainActor static func describe(_ e: Qqbridge_V1_ChatEvent, context: MessageContext) -> String {
    let data = (try? JSONSerialization.jsonObject(with: Data(e.dataJson.utf8)) as? [String: Any]) ?? [:]
    let actor = e.actorID == 0 ? "" : context.name(of: e.actorID)
    let target = e.targetID == 0 ? "" : context.name(of: e.targetID)
    switch e.kind {
    case "member_join":
      // 邀请进群：带上邀请人（actor 是邀请人；同意申请进群时 actor 是同意的管理员，不写）。
      if (data["via"] as? String) == "invite", !actor.isEmpty, !target.isEmpty, e.actorID != e.targetID {
        return "\(actor) 邀请 \(target) 加入了群聊"
      }
      return "\(target.isEmpty ? actor : target) 加入了群聊"
    case "member_leave":
      let how = data["how"] as? String
      if how == "kick" || how == "kick_me", !actor.isEmpty, !target.isEmpty { return "\(target) 被 \(actor) 移出了群聊" }
      return "\(target.isEmpty ? actor : target) 离开了群聊"
    case "admin_set": return "\(target) 成为管理员"
    case "admin_unset": return "\(target) 不再是管理员"
    case "mute":
      if target.isEmpty { return "\(actor) 开启了全员禁言" }
      let secs = data["duration"] as? Double ?? Double(data["duration"] as? Int ?? 0)
      let by = actor.isEmpty ? "被" : "被 \(actor) "
      return secs > 0 ? "\(target) \(by)禁言 \(Format.remaining(secs))" : "\(target) 被禁言"
    case "unmute": return target.isEmpty ? "\(actor) 关闭了全员禁言" : "\(target) 被\(actor.isEmpty ? "" : " \(actor) ")解除禁言"
    case "card_change":
      let new = data["cardNew"] as? String ?? ""
      return new.isEmpty ? "\(target) 清空了群名片" : "\(target) 修改群名片为「\(new)」"
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
  /// 左滑露出的时间：今天只有时刻，昨天"昨天 18:30"，今年"10-05 18:30"，更早带年份。
  /// 气泡里的时间：只要时刻（日期看上面的日期分隔）。
  @MainActor static func clockTime(_ unix: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(unix)).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
  }

  @MainActor static func messageTime(_ unix: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unix))
    let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
    let cal = Calendar.current
    if cal.isDateInToday(date) { return time }
    if cal.isDateInYesterday(date) { return "昨天 \(time)" }
    let day = DateFormatter.cached(cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MM-dd" : "yyyy-MM-dd").string(from: date)
    return "\(day) \(time)"
  }

  /// 往上翻时顶部的日期：今天 / 昨天 / 10-05（一年内）/ 2024-10-05（一年以前）。
  @MainActor static func dayBadge(_ unix: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unix))
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "今天" }
    if cal.isDateInYesterday(date) { return "昨天" }
    let withinYear = date > cal.date(byAdding: .year, value: -1, to: Date())!
    return DateFormatter.cached(withinYear ? "MM-dd" : "yyyy-MM-dd").string(from: date)
  }

  static func chatTime(_ unix: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unix))
    if Calendar.current.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale)) }
    return date.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
  }

  static func duration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  /// 禁言之类的时长：「29 天 23 小时」「2 小时 3 分」「5 分 12 秒」。
  static func remaining(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded(.up)))
    let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60, sec = t % 60
    if d > 0 { return h > 0 ? "\(d) 天 \(h) 小时" : "\(d) 天" }
    if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
    if m > 0 { return "\(m) 分 \(sec) 秒" }
    return "\(sec) 秒"
  }
}

extension DateFormatter {
  @MainActor private static var formatters: [String: DateFormatter] = [:]

  @MainActor static func cached(_ format: String) -> DateFormatter {
    if let f = formatters[format] { return f }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    formatters[format] = f
    return f
  }
}

/// 画 @ 徽章：淡色胶囊底、左边圆头像（没有头像时是名字首字的彩色圆）、@名字。按名字、头像、配色、字号缓存。
@MainActor
enum MentionBadgeRenderer {
  private static var cache: [String: (image: UIImage, baselineOffset: CGFloat)] = [:]

  static func render(name: String, avatar: UIImage?, outgoing: Bool) -> (image: UIImage, baselineOffset: CGFloat) {
    let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize - 1, weight: .semibold)
    let key = "\(name)|\(avatar.map { ObjectIdentifier($0).hashValue } ?? 0)|\(outgoing)|\(font.pointSize)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
    if let hit = cache[key] { return hit }

    let text = "@\(name)" as NSString
    let tint = outgoing ? UIColor.white : UIColor.tintColor.resolvedColor(with: .current)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
    let height = ceil(font.lineHeight + 4)
    let avatarSide = height - 6
    let padH: CGFloat = 7
    // 名字太长（有的群名片很长）：最多 200pt，超出的用省略号，徽章不会被气泡边缘切掉。
    let full = text.size(withAttributes: attrs)
    let textSize = CGSize(width: min(full.width, 200), height: full.height)
    let width = ceil(3 + avatarSide + 4 + textSize.width + padH)
    let size = CGSize(width: width, height: height)

    let image = UIGraphicsImageRenderer(size: size).image { _ in
      let bg = outgoing ? UIColor.white.withAlphaComponent(0.22) : UIColor.tintColor.withAlphaComponent(0.13)
      bg.setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
      let avatarRect = CGRect(x: 3, y: 3, width: avatarSide, height: avatarSide)
      if let avatar {
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        UIBezierPath(ovalIn: avatarRect).addClip()
        avatar.draw(in: avatarRect)
        ctx?.restoreGState()
      } else {
        tint.withAlphaComponent(outgoing ? 0.35 : 0.25).setFill()
        UIBezierPath(ovalIn: avatarRect).fill()
        let initial = String(name.prefix(1)) as NSString
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: avatarSide * 0.55, weight: .bold), .foregroundColor: tint]
        let s = initial.size(withAttributes: small)
        initial.draw(at: CGPoint(x: avatarRect.midX - s.width / 2, y: avatarRect.midY - s.height / 2), withAttributes: small)
      }
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      var clipped = attrs
      clipped[.paragraphStyle] = style
      text.draw(in: CGRect(x: avatarRect.maxX + 4, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height), withAttributes: clipped)
    }
    // 图片底边落在基线上：往下挪到文字下沿，胶囊和正文居中对齐。
    let result = (image: image, baselineOffset: font.descender - (height - font.lineHeight) / 2)
    if cache.count > 500 { cache.removeAll() }
    cache[key] = result
    return result
  }
}

/// 消息文字里的链接、号码标成可点的链接。
enum Linkify {
  static let numberScheme = "qqbridge-number"
  private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  private static let number = try? NSRegularExpression(pattern: #"(?<![0-9A-Za-z])\d{5,}(?![0-9A-Za-z])"#)

  static func attributed(_ string: String) -> AttributedString {
    var out = AttributedString(string)
    let ns = string as NSString
    let all = NSRange(location: 0, length: ns.length)
    var taken: [NSRange] = []
    for m in detector?.matches(in: string, range: all) ?? [] {
      guard let url = m.url, let r = Range(m.range, in: out) else { continue }
      // 邮箱、电话之类的 link 也算；只有纯数字的不当链接（交给下面的号码）。
      if ns.substring(with: m.range).allSatisfy(\.isNumber) { continue }
      out[r].link = url.scheme == nil ? URL(string: "https://\(ns.substring(with: m.range))") : url
      out[r].underlineStyle = .single
      taken.append(m.range)
    }
    for m in number?.matches(in: string, range: all) ?? [] {
      guard !taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }), let r = Range(m.range, in: out) else { continue }
      out[r].link = URL(string: "\(numberScheme)://\(ns.substring(with: m.range))")
      out[r].underlineStyle = .single
    }
    return out
  }

  /// 像手机号（中国大陆 11 位，1 开头）。
  static func isPhone(_ n: String) -> Bool { n.count == 11 && n.hasPrefix("1") }

  /// 可能是 QQ 号（5–11 位，不以 0 开头）。
  static func isQQ(_ n: String) -> Bool { (5...11).contains(n.count) && !n.hasPrefix("0") }
}

/// 文字里 @ 徽章的标记（徽章是一张图，靠它找到图在哪、是谁）。
struct MentionTag: TextAttribute {
  let userId: Int64
}

/// 消息正文：链接、号码可点；@ 徽章单击在输入框里 @ 这个人，长按打开 TA 的资料卡。
struct MentionText: View {
  let runs: [Inline]
  let context: MessageContext
  let outgoing: Bool
  var seq: Int64 = 0
  /// 末尾留出的位置（透明的同宽文字，给气泡右下角的时间让位）。
  var reserve: String? = nil
  @State private var badges: [MentionHit] = []
  /// 正按着的徽章（-1 = 挪开了，不算点）。
  @State private var pressing: Int64?
  @State private var longFired = false
  @State private var pressTimer: Task<Void, Never>?

  private var mentioned: [Int64] {
    runs.compactMap { if case .mention(let id, _, let avatar) = $0, avatar == nil { id } else { nil } }
  }

  var body: some View {
    let composed = Inline.compose(runs, outgoing: outgoing)
    let text = (reserve.map { composed + Text("\u{2002}\u{2002}\($0)").font(.caption2.monospacedDigit()).foregroundStyle(.clear) } ?? composed)
      .tint(outgoing ? .white : .accentColor)
      .textSelection(.enabled)
      // 链接用系统打开；号码（5 位以上）交给聊天页：查 QQ 用户、拨打、复制。
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == Linkify.numberScheme, let number = url.host() else { return .systemAction }
        context.actions.openNumber(number)
        return .handled
      })
    if runs.contains(where: { if case .mention = $0 { true } else { false } }) {
      text
        .textRenderer(MentionLocator { hits in if hits != badges { DispatchQueue.main.async { badges = hits } } })
        .overlay(alignment: .topLeading) {
          ForEach(badges) { hit in
            Color.clear
              .contentShape(Capsule())
              .frame(width: hit.rect.width, height: hit.rect.height)
              .offset(x: hit.rect.minX, y: hit.rect.minY)
              // 自己判断单击 / 长按（系统的长按会被气泡的菜单抢走）：按下就记下，气泡据此不弹菜单；
              // 按住 0.4 秒没挪开 = 长按（打开资料卡），之前松手 = 单击（在输入框里 @ TA）；挪开了算滚动，什么都不做。
              .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                  .onChanged { v in
                    if pressing == nil {
                      MentionPress.shared.seq = seq
                      pressing = hit.userId
                      longFired = false
                      pressTimer?.cancel()
                      pressTimer = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled, pressing == hit.userId else { return }
                        longFired = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        context.actions.showProfile(hit.userId)
                      }
                    } else if hypot(v.translation.width, v.translation.height) > 10 {
                      pressTimer?.cancel()
                      pressing = -1
                    }
                  }
                  .onEnded { v in
                    pressTimer?.cancel()
                    if pressing == hit.userId, !longFired, hypot(v.translation.width, v.translation.height) <= 10 {
                      context.actions.mention(hit.userId)
                    }
                    pressing = nil
                    MentionPress.shared.release(seq)
                  }
              )
          }
        }
        .onAppear {
          // 头像还没在内存里的：要来、读进内存，徽章随后重画出头像。
          for id in mentioned { context.avatars.wantImage(id, knownSha: context.lookup.avatar(id), session: context.session) }
        }
    } else {
      text
    }
  }
}

struct MentionHit: Identifiable, Equatable {
  let id: Int
  let userId: Int64
  let rect: CGRect
}

/// 画文字时顺带记下每个 @ 徽章的位置（画法和默认一样）。
struct MentionLocator: TextRenderer {
  let report: @Sendable ([MentionHit]) -> Void

  func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
    var hits: [MentionHit] = []
    for line in layout {
      for run in line {
        if let tag = run[MentionTag.self] {
          hits.append(MentionHit(id: hits.count, userId: tag.userId, rect: run.typographicBounds.rect))
        }
      }
      ctx.draw(line)
    }
    report(hits)
  }
}

/// 表情：加载时显示一块泛着波纹的点阵，加载好后从中间羽化地揭开；实在拿不到才显示文字。
struct StickerImage: View {
  let sha256: String?
  let chatId: Int64
  let summary: String
  @State private var failed = false

  var body: some View {
    if failed {
      Text(summary.isEmpty ? "[表情]" : summary).font(.caption).foregroundStyle(.secondary)
    } else {
      CachedImage(sha256: sha256, chatId: chatId, onFailure: { failed = true }, maxPixel: 420, animated: true, reveal: true) {
        RippleCanvas()
      }
      .aspectRatio(contentMode: .fit)
    }
  }
}

/// 加载中：点阵从中心一圈圈泛起波纹，底下一层柔和的渐变慢慢流动。
struct RippleCanvas: View {
  var body: some View {
    TimelineView(.animation) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      Canvas { ctx, size in
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // 底：两团慢慢绕圈的柔光。
        for (i, color) in [Color.accentColor, Color.purple].enumerated() {
          let a = t * 0.8 + Double(i) * .pi
          let p = CGPoint(x: center.x + cos(a) * size.width * 0.18, y: center.y + sin(a) * size.height * 0.18)
          let r = max(size.width, size.height) * 0.55
          ctx.fill(
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(Gradient(colors: [color.opacity(0.18), .clear]), center: p, startRadius: 0, endRadius: r)
          )
        }
        // 点阵：离中心越远相位越晚，形成往外扩的波纹。
        let step: CGFloat = 9
        var y = step / 2
        while y < size.height {
          var x = step / 2
          while x < size.width {
            let d = hypot(x - center.x, y - center.y)
            let wave = (sin(d / 9 - t * 4) + 1) / 2
            let r = 0.8 + wave * 1.3
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.secondary.opacity(0.15 + wave * 0.45)))
            x += step
          }
          y += step
        }
      }
    }
    .background(.quaternary.opacity(0.35))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

/// 正按在哪条消息的 @ 徽章上（那条消息的气泡暂时不弹长按菜单）。
@MainActor
@Observable
final class MentionPress {
  static let shared = MentionPress()
  var seq: Int64?

  /// 松手后稍等再放开（长按菜单是在松手前判断的）。
  func release(_ seq: Int64) {
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      if self.seq == seq { self.seq = nil }
    }
  }
}

// MARK: - 小程序卡片

/// 小程序 / 分享卡片里能用的东西：来源、标题、简介、封面、能用浏览器打开的链接。
struct AppCard {
  let source: String
  let icon: URL?
  let title: String
  let desc: String
  let preview: URL?
  let url: URL?
  /// 群相册卡片：点开看这个相册。
  var album: AlbumRef? = nil

  static func parse(json: String, app: String) -> AppCard? {
    guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let meta = obj["meta"] as? [String: Any], let detail = meta.values.compactMap({ $0 as? [String: Any] }).first
    else { return nil }
    func str(_ keys: String...) -> String {
      for k in keys { if let v = detail[k] as? String, !v.isEmpty { return v } }
      return ""
    }
    func link(_ s: String) -> URL? {
      guard !s.isEmpty else { return nil }
      // mqqapi://、mqzone:// 之类只有 QQ 能打开的链接不要。
      if s.contains("://"), !s.hasPrefix("http") { return nil }
      // http 链接（QQ 的图床大多也支持 https）换成 https，否则 iOS 不让加载。
      let full = s.hasPrefix("https") ? s : s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : "https://\(s)"
      guard let u = URL(string: full), u.host() != nil else { return nil }
      return u
    }
    // 小程序：qqdocurl 是网页版（哔哩哔哩是 b23.tv 短链）；分享卡片：jumpUrl。m.q.qq.com 的小程序链接浏览器打不开，不用。
    let candidates = [str("qqdocurl"), str("jumpUrl", "jumpurl"), str("url")].compactMap(link).filter { $0.host() != "m.q.qq.com" }
    let title = str("title")
    let desc = str("desc", "summary", "forwardMessage")
    guard !title.isEmpty || !desc.isEmpty else { return nil }
    // 群相册：jumpUrl 里带群号和相册 id。
    if (obj["bizsrc"] as? String)?.hasPrefix("group_album") == true || str("jumpUrl").contains("groupalbum") {
      let q = URLComponents(string: str("jumpUrl"))?.queryItems ?? []
      func v(_ n: String) -> String { q.first { $0.name.lowercased() == n.lowercased() }?.value ?? "" }
      if let gid = Int64(v("groupid").isEmpty ? v("groupCode") : v("groupid")), !v("albumid").isEmpty {
        return AppCard(
          source: str("tagName").isEmpty ? "群相册" : str("tagName"),
          icon: nil,
          title: title,
          desc: desc,
          preview: link(str("cover", "preview")),
          url: nil,
          album: AlbumRef(groupId: gid, albumId: v("albumid"), title: title.replacingOccurrences(of: "群相册", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "《》 ")))
        )
      }
    }
    // 小程序的 title 是小程序名（哔哩哔哩），desc 才是内容标题。
    let isMini = detail["appid"] != nil
    return AppCard(
      source: isMini ? title : (str("tag").isEmpty ? (obj["prompt"] as? String ?? app) : str("tag")),
      icon: link(str("icon", "source_icon")),
      title: isMini ? desc : title,
      desc: isMini ? "" : desc,
      preview: link(str("preview", "cover")),
      url: candidates.first
    )
  }
}

struct AppCardView: View {
  let card: AppCard
  let outgoing: Bool
  var onAlbum: (AlbumRef) -> Void = { _ in }
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      if let album = card.album { onAlbum(album) } else if let url = card.url { openURL(url) }
    } label: { content }
    .buttonStyle(.plain)
    .disabled(card.url == nil && card.album == nil)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        if let icon = card.icon {
          AsyncImage(url: icon) { $0.resizable() } placeholder: { Color.secondary.opacity(0.2) }
            .frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        Text(card.source).font(.caption).opacity(0.75).lineLimit(1)
      }
      Text(card.title).font(.subheadline.weight(.medium)).lineLimit(3)
      if !card.desc.isEmpty { Text(card.desc).font(.caption).opacity(0.75).lineLimit(2) }
      if let preview = card.preview {
        RemoteImage(url: preview, maxPixel: 600)
          .frame(width: 236, height: card.album != nil ? 236 : 133)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
      if card.album != nil {
        Label("查看相册", systemImage: "photo.on.rectangle.angled").font(.caption2).opacity(0.7)
      } else if card.url != nil {
        Label("在浏览器中打开", systemImage: "safari").font(.caption2).opacity(0.7)
      }
    }
    .frame(width: 236, alignment: .leading)
    .contentShape(Rectangle())
  }
}

// MARK: - 机器人 markdown、按钮

/// 机器人的 markdown：图片单独成块（按 alt 里的 #宽px #高px 定比例），其余按行内 markdown 显示；
/// @（mqqapi://markdown/mention）换成粗体的 @名字。
struct MarkdownBlock: View {
  let content: String
  let outgoing: Bool

  enum Part {
    case text(AttributedString)
    case image(URL, CGFloat?)
  }

  static func parts(_ content: String) -> [Part] {
    var out: [Part] = []
    var buffer = ""
    func flushText() {
      let t = buffer.trimmingCharacters(in: .newlines)
      buffer = ""
      guard !t.isEmpty else { return }
      var md = t.replacingOccurrences(of: #"\[(@[^\]]+)\]\(mqqapi://[^)]*\)"#, with: "**$1**", options: .regularExpression)
      // 标题：显示成粗体。
      md = md.replacingOccurrences(of: #"(?m)^#{1,6}\s*(.+)$"#, with: "**$1**", options: .regularExpression)
      let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
      out.append(.text((try? AttributedString(markdown: md, options: opts)) ?? AttributedString(t)))
    }
    let image = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\((\S+?)\)"#)
    let ns = content as NSString
    var cursor = 0
    for m in image?.matches(in: content, range: NSRange(location: 0, length: ns.length)) ?? [] {
      buffer += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
      flushText()
      let alt = ns.substring(with: m.range(at: 1))
      let nums = alt.matches(of: /#(\d+)px/).compactMap { Double($0.1) }
      let ratio = nums.count >= 2 && nums[0] > 0 ? CGFloat(nums[1] / nums[0]) : nil
      if let url = URL(string: ns.substring(with: m.range(at: 2))) { out.append(.image(url, ratio)) }
      cursor = m.range.location + m.range.length
    }
    buffer += ns.substring(from: cursor)
    flushText()
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(Self.parts(content).enumerated()), id: \.offset) { _, part in
        switch part {
        case .text(let a):
          Text(a).tint(outgoing ? .white : .accentColor).textSelection(.enabled)
        case .image(let url, let ratio):
          AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { RippleCanvas() }
            .frame(width: 240, height: ratio.map { min(240 * $0, 520) } ?? 180)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      }
    }
  }
}

/// 机器人消息下面的一个按钮。type：0 跳链接、1 回调（只能在 QQ 里点）、2 指令（发一句话给机器人）。
struct BotButton: Identifiable {
  let id: String
  let label: String
  let data: String
  let type: Int
  /// 指令按钮：true = 点了直接发送，false = 填进输入框。
  let enter: Bool

  static func parse(_ json: String) -> [[BotButton]] {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let kb = obj["inlineKeyboardElement"] as? [String: Any], let rows = kb["rows"] as? [[String: Any]]
    else { return [] }
    return rows.enumerated().compactMap { r, row in
      let buttons = (row["buttons"] as? [[String: Any]] ?? []).enumerated().map { i, b in
        BotButton(
          id: "\(r).\(i)",
          label: b["label"] as? String ?? "",
          data: b["data"] as? String ?? "",
          type: (b["type"] as? Int) ?? Int(b["type"] as? String ?? "") ?? 2,
          enter: b["enter"] as? Bool ?? false
        )
      }.filter { !$0.label.isEmpty }
      return buttons.isEmpty ? nil : buttons
    }
  }
}

struct BotKeyboard: View {
  let rows: [[BotButton]]
  let outgoing: Bool
  let onTap: (BotButton) -> Void

  var body: some View {
    VStack(spacing: 6) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 6) {
          ForEach(row) { b in
            Button { onTap(b) } label: {
              HStack(spacing: 4) {
                if b.type == 0 { Image(systemName: "link").font(.caption2) }
                Text(b.label).font(.footnote.weight(.medium)).lineLimit(1)
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 7)
              .background(RoundedRectangle(cornerRadius: 8).strokeBorder(outgoing ? Color.white.opacity(0.6) : Color.accentColor.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(outgoing ? Color.white : Color.accentColor)
          }
        }
      }
    }
    .frame(minWidth: 220)
  }
}
