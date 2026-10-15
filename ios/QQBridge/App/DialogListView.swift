import QQBridgeKit
import QQBridgeProto
import SwiftUI

/// 会话列表。收进群助手的群折叠成一行"群助手"，点进去是它们自己的列表。
struct DialogListView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var items: [DialogItem] = []
  @State private var path = NavigationPath()
  /// 上一次"再点消息标签"跳到的会话：下次从它后面接着找。
  @State private var lastJumped: Int64?

  private var visible: [DialogItem] { items.filter { !$0.isArchived } }
  private var archived: [DialogItem] { items.filter(\.isArchived) }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollViewReader { proxy in
      List {
        let pinned = visible.filter(\.dialog.pinned)
        let rest = visible.filter { !$0.dialog.pinned }
        ForEach(pinned) { row($0) }
        // 群助手按它里面最新一条消息的时间插在普通会话之间。
        let archiveTime = archived.map(\.dialog.topTime).max() ?? 0
        ForEach(rest.filter { $0.dialog.topTime >= archiveTime }) { row($0) }
        if !archived.isEmpty {
          NavigationLink(value: Route.archive) {
            ArchiveRow(items: archived)
          }
          .navigationLinkIndicatorVisibility(.hidden)
        }
        ForEach(rest.filter { $0.dialog.topTime < archiveTime }) { row($0) }
      }
      .listStyle(.plain)
      .onChange(of: model.nextUnreadTick) { jumpToNextUnread(proxy) }
      }
      .navigationTitle("消息")
      .navigationDestination(for: Route.self) { route in
        switch route {
        case .chat(let id): ChatScreen(session: session, chatId: id)
        case .archive: ArchivedListView(session: session)
        }
      }
      .refreshable {
        try? await session.sync.catchUp()
        await session.sync.prefetch()
      }
      .overlay {
        if items.isEmpty, model.connection == .online {
          ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right")
        }
      }
    }
    .task {
      do {
        for try await list in session.store.observeDialogs() {
          items = list
          model.updateBadge(list)
        }
      } catch {}
    }
    .onChange(of: model.pendingChat, initial: true) { _, chatId in
      guard let chatId else { return }
      model.pendingChat = nil
      guard !path.isEmpty else {
        path.append(Route.chat(chatId))
        return
      }
      // 已经在别的会话里：先退回列表，下一帧再进目标会话（同一帧里替换整个路径有时不生效）。
      path = NavigationPath()
      Task {
        try? await Task.sleep(for: .milliseconds(350))
        path.append(Route.chat(chatId))
      }
    }
  }

  /// 再点一次"消息"标签：在会话里就先回到列表；在列表就滚到下一个有未读（算进角标的）的会话，到底了从头再来。
  private func jumpToNextUnread(_ proxy: ScrollViewProxy) {
    if !path.isEmpty {
      path = NavigationPath()
      return
    }
    // 和列表的显示顺序一致（群助手里的不算，它们在单独的列表里）。
    let pinned = visible.filter(\.dialog.pinned)
    let rest = visible.filter { !$0.dialog.pinned }
    let order = (pinned + rest).filter { $0.badgeCount > 0 }.map(\.id)
    guard !order.isEmpty else { return }
    let next: Int64
    if let last = lastJumped, let i = order.firstIndex(of: last), i + 1 < order.count {
      next = order[i + 1]
    } else {
      next = order[0]
    }
    lastJumped = next
    withAnimation { proxy.scrollTo(next, anchor: .top) }
  }

  private func row(_ item: DialogItem) -> some View {
    DialogLink(item: item, session: session, typing: model.isTyping(item.id))
  }
}

enum Route: Hashable {
  case chat(Int64)
  case archive
}

/// 一行会话，带左右滑动操作和长按菜单。
struct DialogLink: View {
  let item: DialogItem
  let session: Session
  let typing: Bool

  var body: some View {
    NavigationLink(value: Route.chat(item.id)) {
      DialogRow(item: item, typing: typing)
    }
    .navigationLinkIndicatorVisibility(.hidden)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .listRowBackground(item.dialog.pinned ? Color.secondary.opacity(0.08) : nil)
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if item.dialog.unreadCount > 0 {
        Button { DialogActions.markRead(item, session) } label: { Label("已读", systemImage: "checkmark.message") }
          .tint(.blue)
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button { DialogActions.togglePinned(item, session) } label: {
        Label(item.dialog.pinned ? "取消置顶" : "置顶", systemImage: item.dialog.pinned ? "pin.slash" : "pin")
      }
      .tint(.orange)
      Button { DialogActions.toggleMuted(item, session) } label: {
        Label(item.isMuted ? "提醒" : "免打扰", systemImage: item.isMuted ? "bell" : "bell.slash")
      }
      .tint(.indigo)
      if item.isGroup {
        Button { DialogActions.toggleArchived(item, session) } label: {
          Label(item.isArchived ? "移出群助手" : "收进群助手", systemImage: item.isArchived ? "tray.and.arrow.up" : "tray.and.arrow.down")
        }
        .tint(.gray)
      }
    }
    .contextMenu {
      if item.dialog.unreadCount > 0 {
        Button("标为已读", systemImage: "checkmark.message") { DialogActions.markRead(item, session) }
      }
      Button(item.dialog.pinned ? "取消置顶" : "置顶", systemImage: "pin") { DialogActions.togglePinned(item, session) }
      Button(item.isMuted ? "接收并提醒" : "接收不提醒", systemImage: "bell") { DialogActions.toggleMuted(item, session) }
      if item.isGroup {
        Button(item.isArchived ? "移出群助手" : "收进群助手", systemImage: "tray") { DialogActions.toggleArchived(item, session) }
      }
    }
  }
}

/// 会话操作：直接调服务端，结果经同步回到本地库，列表自己刷新。
enum DialogActions {
  static func markRead(_ item: DialogItem, _ session: Session) {
    Task { _ = try? await session.api.markRead(chatId: item.id, maxSeq: item.dialog.topSeq) }
  }

  static func togglePinned(_ item: DialogItem, _ session: Session) {
    var req = Qqbridge_V1_SetPinnedRequest()
    req.chatID = item.id
    req.pinned = !item.dialog.pinned
    Task { _ = await session.api.dialogs.setPinned(request: req, headers: session.api.headers) }
  }

  static func toggleMuted(_ item: DialogItem, _ session: Session) {
    setPolicy(item.id, session, item.isMuted ? (item.isGroup ? "all" : "default") : "muted")
  }

  static func toggleArchived(_ item: DialogItem, _ session: Session) {
    setPolicy(item.id, session, item.isArchived ? "muted" : "archived")
  }

  static func setPolicy(_ chatId: Int64, _ session: Session, _ policy: String) {
    var req = Qqbridge_V1_SetNotifyPolicyRequest()
    req.chatID = chatId
    req.policy = policy
    Task { _ = await session.api.dialogs.setNotifyPolicy(request: req, headers: session.api.headers) }
  }
}

/// 群助手：折叠起来的那一行。
struct ArchiveRow: View {
  let items: [DialogItem]
  /// 尺寸与普通会话行共用一份样式（iOS 用默认值；桌面侧栏由调用方传入更紧凑的值）。
  var style = DialogRowStyle.standard
  /// 和普通会话行一样大（三行预览时头像也跟着变大）。
  @AppStorage(DialogRow.linesKey) private var lines = 2

  var body: some View {
    let latest = items.max { $0.dialog.topTime < $1.dialog.topTime }
    let unreadChats = items.filter { $0.dialog.unreadCount > 0 }.count
    HStack(spacing: style.spacing) {
      ZStack {
        Circle().fill(Color.gray.gradient)
        Image(systemName: "archivebox.fill").font(lines == 3 ? .title2 : .title3).foregroundStyle(.white)
      }
      .frame(width: style.avatarSize(lines: lines), height: style.avatarSize(lines: lines))
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("群助手").font(.body.weight(.semibold))
          Spacer()
          if let latest { Text(Format.listTime(latest.dialog.topTime)).font(.caption).foregroundStyle(.secondary) }
        }
        HStack {
          if let latest {
            Text("\(latest.title)：\(Format.preview(latest.dialog.topMessage))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if unreadChats > 0 {
            Text("\(unreadChats)").font(.caption.bold().monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 2)
              .background(Color.secondary.opacity(0.6), in: Capsule()).foregroundStyle(.white)
          }
        }
      }
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
  }
}

/// 群助手里的群（自己观察本地库，在里面操作完列表也会跟着变）。
struct ArchivedListView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var items: [DialogItem] = []

  var body: some View {
    List(items) { DialogLink(item: $0, session: session, typing: model.isTyping($0.id)) }
      .listStyle(.plain)
      .navigationTitle("群助手")
      .navigationBarTitleDisplayMode(.inline)
      .task {
        do {
          for try await list in session.store.observeDialogs() { items = list.filter(\.isArchived) }
        } catch {}
      }
  }
}

/// 会话行的尺寸参数。默认值即 iOS 原有外观；只描述尺寸，不含平台专属类型。
struct DialogRowStyle {
  /// 两行预览时的头像边长。
  var avatar: CGFloat = 48
  /// 三行预览时的头像边长。
  var tallAvatar: CGFloat = 56
  /// 头像与文字的间距。
  var spacing: CGFloat = 12

  static let standard = DialogRowStyle()

  func avatarSize(lines: Int) -> CGFloat { lines == 3 ? tallAvatar : avatar }
}

struct DialogRow: View {
  static let linesKey = "dialogPreviewLines"
  let item: DialogItem
  let typing: Bool
  var style = DialogRowStyle.standard
  @Environment(\.session) private var session
  @Environment(AppModel.self) private var model

  /// 这个群正在群语音（收到了邀请、或者自己在里面）。
  private var inVoice: Bool {
    guard item.isGroup, let call = model.calls.call, call.groupID == item.dialog.peerID else { return false }
    return call.phase != .ended
  }
  /// 2：会话名 +「发送者：内容」；3：会话名、发送者、内容各一行。
  @AppStorage(DialogRow.linesKey) private var lines = 2

  var body: some View {
    HStack(spacing: style.spacing) {
      AvatarView(sha256: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID, size: style.avatarSize(lines: lines))
      VStack(alignment: .leading, spacing: lines == 3 ? 2 : 4) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
          if item.isMuted {
            Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
          }
          if inVoice {
            Label("语音中", systemImage: "waveform")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Capsule().fill(Color.green))
              .fixedSize()
          }
          Spacer(minLength: 8)
          Text(Format.listTime(item.dialog.topTime)).font(.caption).foregroundStyle(.secondary)
        }
        HStack(alignment: lines == 3 ? .bottom : .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 1) {
            if lines == 3, let sender, !typing {
              Text(sender).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            }
            preview.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 8)
          Badges(dialog: item.dialog, muted: item.isMuted)
        }
      }
    }
  }

  /// 顶部消息的发送者：群里显示名字（群名片 > 昵称），自己发的显示"我"；私聊只在自己发的时候显示"我"。
  private var sender: String? {
    let m = item.dialog.topMessage
    guard m.seq > 0, m.kind == .normal, item.dialog.draft.segments.isEmpty else { return nil }
    let selfUin = (try? session?.store.selfUin(qqAccountId: item.dialog.qqAccountID)) ?? 0
    if m.senderID == selfUin { return "我" }
    guard item.isGroup else { return nil }
    if !m.senderName.isEmpty { return m.senderName }
    return (try? session?.store.userName(qqAccountId: item.dialog.qqAccountID, userId: m.senderID)) ?? String(m.senderID)
  }

  /// 两行模式里内容前面带上"发送者："。
  private var body2: Text {
    let content = Text(Format.preview(item.dialog.topMessage))
    // 名字太长（有的群名片几十个字）时截短，免得把内容挤没了。
    if lines == 2, let sender {
      let short = sender.count > 10 ? String(sender.prefix(10)) + "…" : sender
      return Text("\(short)：").foregroundStyle(.primary.opacity(0.75)) + content
    }
    return content
  }

  @ViewBuilder private var preview: some View {
    let d = item.dialog
    if typing {
      Text("正在输入…").foregroundStyle(.tint)
    } else if !d.draft.segments.isEmpty {
      Text("[草稿] ").foregroundStyle(.red) + Text(d.draft.segments.map(\.text).joined())
    } else if d.unreadMentions > 0 {
      Text("[有人@我] ").foregroundStyle(.red) + body2
    } else if d.unreadReplies > 0 {
      Text("[有人回复我] ").foregroundStyle(.green) + body2
    } else if d.unreadMentionAll > 0, d.mentionAllNotify {
      Text("[@全体成员] ").foregroundStyle(.orange) + body2
    } else {
      body2
    }
  }
}

/// 未读标记：@我（红 @）、回复我（绿 ↩）、@全体成员（橙"全"；关掉了 @全体成员 提醒时不显示）各一个圆标，
/// 再加未读数（接收不提醒、群助手是灰色，提醒的是主题色）。
struct Badges: View {
  let dialog: Qqbridge_V1_Dialog
  let muted: Bool

  var body: some View {
    HStack(spacing: 4) {
      if dialog.unreadMentions > 0 {
        mark(Text("@").font(.caption.bold()), .red)
      }
      if dialog.unreadReplies > 0 {
        mark(Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9, weight: .bold)), .green)
      }
      if dialog.unreadMentionAll > 0, dialog.mentionAllNotify {
        mark(Text("全").font(.system(size: 10, weight: .bold)), .orange)
      }
      if dialog.unreadCount > 0 {
        Text(dialog.unreadCount > 99 ? "99+" : "\(dialog.unreadCount)")
          .font(.caption.bold().monospacedDigit())
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(muted ? Color.secondary.opacity(0.6) : Color.accentColor, in: Capsule())
          .foregroundStyle(.white)
      }
    }
  }

  private func mark(_ content: some View, _ color: Color) -> some View {
    content.foregroundStyle(.white).frame(width: 20, height: 20).background(color, in: Circle())
  }
}

/// 文案与时间格式。
enum Format {
  static let locale = Locale(identifier: "zh_Hans_CN")

  /// 会话列表的时间：今天显示时刻，一周内显示星期，再早显示日期。
  static func listTime(_ unix: Int64) -> String {
    guard unix > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(unix))
    let cal = Calendar.current
    if cal.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale)) }
    if cal.isDateInYesterday(date) { return "昨天" }
    if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
      return date.formatted(.dateTime.weekday(.wide).locale(locale))
    }
    return date.formatted(.dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits).locale(locale))
  }

  /// 消息的一行预览。
  static func preview(_ m: Qqbridge_V1_Message) -> String {
    // 撤回的消息照样显示内容，前面标一下。
    m.state == .recalled ? "[已撤回] " + content(m) : content(m)
  }

  private static func content(_ m: Qqbridge_V1_Message) -> String {
    // 卡片：用卡片自己的标题（以前的数据里 text 是「[卡片] com.tencent.xxx」）。
    for seg in m.segments { if case .lightApp(let a) = seg.kind { return CardText.from(json: a.json, app: a.appName) } }
    // 不支持的元素：服务端以前的文字是「[nt:9]」这样的类型号，换成能看懂的一句（「[QQ红包] 恭喜发财」）。
    if !m.text.isEmpty {
      var text = m.text
      for item in m.unsupportedItems { text = text.replacingOccurrences(of: "[\(item.original)]", with: item.preview) }
      return text
    }
    for seg in m.segments {
      switch seg.kind {
      case .image(let i): return i.sticker ? "[表情]" : "[图片]"
      case .record: return "[语音]"
      case .video: return "[视频]"
      case .file(let f): return "[文件] \(f.name)"
      case .forward: return "[聊天记录]"
      case .marketFace(let f): return f.summary.isEmpty ? "[表情]" : f.summary
      case .lightApp: return "[卡片]"
      default: continue
      }
    }
    return ""
  }
}
