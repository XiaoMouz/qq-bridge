// 聊天记录搜索的筛选：发送者（只看 / 排除）、会话（全局搜索，只搜 / 排除）、时间范围、内容类型、排序。
// 首页搜索、会话里的查找、Mac 侧栏搜索和 Mac 会话检查器里的查找共用这一套（2026-11-08 用户要求）。
// 界面按「不加多余的说明文字，让布局自己说话」：一排胶囊，选了什么胶囊上就写什么。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct SearchPerson: Hashable, Identifiable, Sendable {
  let id: Int64
  let name: String
}

struct SearchChat: Hashable, Identifiable, Sendable {
  let id: Int64
  let name: String
}

enum SearchKind: String, CaseIterable, Identifiable, Sendable {
  case photo, video, file, voice, link, mention
  var id: String { rawValue }
  var title: String {
    switch self {
    case .photo: "图片"
    case .video: "视频"
    case .file: "文件"
    case .voice: "语音"
    case .link: "链接"
    case .mention: "@我"
    }
  }
  var icon: String {
    switch self {
    case .photo: "photo"
    case .video: "video"
    case .file: "doc"
    case .voice: "waveform"
    case .link: "link"
    case .mention: "at"
    }
  }
  /// 服务端的 MessageFlag 位（packages/domain/src/segments.ts）。
  var flags: UInt32 {
    switch self {
    case .photo: 1 << 0
    case .video: 1 << 1
    case .voice: 1 << 2
    case .file: 1 << 3
    case .link: 1 << 4
    case .mention: (1 << 5) | (1 << 6) | (1 << 8)
    }
  }
}

struct MessageSearchFilter: Equatable, Sendable {
  enum Mode: String, CaseIterable, Sendable { case only, exclude }
  var peopleMode = Mode.only
  var people: [SearchPerson] = []
  var chatsMode = Mode.only
  var chats: [SearchChat] = []
  /// 当地日期，含首尾两天。
  var since: Date?
  var until: Date?
  var kinds: Set<SearchKind> = []
  var oldestFirst = false

  var isEmpty: Bool { self == MessageSearchFilter() }
  /// 除了排序以外有没有筛选条件（没有关键词时至少要有一个）。
  var narrows: Bool { !people.isEmpty || !chats.isEmpty || since != nil || until != nil || !kinds.isEmpty }

  func apply(to req: inout Qqbridge_V1_SearchMessagesRequest) {
    let peopleIds = people.map(\.id)
    if peopleMode == .only { req.senderIds = peopleIds } else { req.excludeSenderIds = peopleIds }
    let chatIds = chats.map(\.id)
    if chatsMode == .only { req.chatIds = chatIds } else { req.excludeChatIds = chatIds }
    let calendar = Calendar.current
    if let since { req.since = Int64(calendar.startOfDay(for: since).timeIntervalSince1970) }
    if let until, let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: until)) {
      req.until = Int64(end.timeIntervalSince1970)
    }
    req.flagsAny = kinds.reduce(0) { $0 | $1.flags }
    req.oldestFirst = oldestFirst
  }

  /// 没有关键词时能不能搜：服务端只在限定了会话（最多 20 个）时允许，否则全表太慢。
  func allowsEmptyQuery(chatId: Int64) -> Bool {
    guard narrows || oldestFirst else { return false }
    return chatId != 0 || (chatsMode == .only && !chats.isEmpty && chats.count <= 20)
  }

  // MARK: 胶囊上的字

  var peopleLabel: String? {
    guard let first = people.first else { return nil }
    let names = people.count == 1 ? first.name : "\(first.name) 等 \(people.count) 人"
    return peopleMode == .exclude ? "排除 \(names)" : names
  }

  var chatsLabel: String? {
    guard let first = chats.first else { return nil }
    let names = chats.count == 1 ? first.name : "\(first.name) 等 \(chats.count) 个"
    return chatsMode == .exclude ? "排除 \(names)" : names
  }

  var dateLabel: String? {
    guard since != nil || until != nil else { return nil }
    let f = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "zh_CN"))
    let year = Calendar.current.component(.year, from: Date())
    func text(_ d: Date) -> String {
      Calendar.current.component(.year, from: d) == year
        ? d.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))) : d.formatted(f)
    }
    switch (since, until) {
    case let (s?, u?) where Calendar.current.isDate(s, inSameDayAs: u): return text(s)
    case let (s?, u?): return "\(text(s)) – \(text(u))"
    case let (s?, nil): return "\(text(s)) 起"
    case let (nil, u?): return "\(text(u)) 前"
    default: return nil
    }
  }

  var kindsLabel: String? {
    guard !kinds.isEmpty else { return nil }
    return SearchKind.allCases.filter { kinds.contains($0) }.map(\.title).joined(separator: "、")
  }
}

/// 筛选从哪里来：会话里的查找（候选人是这个会话的成员）或全局搜索（候选人是好友，另可选会话）。
enum SearchFilterScope: Equatable {
  case chat(Int64)
  case global
}

/// 一排筛选胶囊（横向滚动）。
struct SearchFilterBar: View {
  @Binding var filter: MessageSearchFilter
  let scope: SearchFilterScope
  let session: Session
  @State private var picking: Sheet?

  enum Sheet: String, Identifiable {
    case people, chats, date
    var id: String { rawValue }
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(filter.peopleLabel ?? "发送者", icon: "person", on: !filter.people.isEmpty) { picking = .people }
        if scope == .global {
          chip(filter.chatsLabel ?? "会话", icon: "bubble.left.and.bubble.right", on: !filter.chats.isEmpty) { picking = .chats }
        }
        chip(filter.dateLabel ?? "时间", icon: "calendar", on: filter.since != nil || filter.until != nil) { picking = .date }
        kindMenu
        orderMenu
        if !filter.isEmpty {
          Button("清除筛选", systemImage: "xmark.circle.fill") { filter = MessageSearchFilter() }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
    }
    .sheet(item: $picking) { which in sheet(which) }
  }

  @ViewBuilder private func sheet(_ which: Sheet) -> some View {
    switch which {
    case .people:
      SearchPeoplePicker(session: session, scope: scope, mode: filter.peopleMode, selected: filter.people) { mode, people in
        filter.peopleMode = mode
        filter.people = people
      }
    case .chats:
      SearchChatsPicker(session: session, mode: filter.chatsMode, selected: filter.chats) { mode, chats in
        filter.chatsMode = mode
        filter.chats = chats
      }
    case .date:
      SearchDatePicker(since: filter.since, until: filter.until) { since, until in
        filter.since = since
        filter.until = until
      }
    }
  }

  private var kindMenu: some View {
    Menu {
      ForEach(SearchKind.allCases) { kind in
        Toggle(isOn: Binding(get: { filter.kinds.contains(kind) }, set: { on in
          if on { filter.kinds.insert(kind) } else { filter.kinds.remove(kind) }
        })) { Label(kind.title, systemImage: kind.icon) }
      }
    } label: {
      SearchChipLabel(text: filter.kindsLabel ?? "类型", icon: "square.grid.2x2", on: !filter.kinds.isEmpty, menu: true)
    }
    .menuActionDismissBehavior(.disabled)
  }

  private var orderMenu: some View {
    Menu {
      Picker("排序", selection: $filter.oldestFirst) {
        Label("最新在前", systemImage: "arrow.down").tag(false)
        Label("最早在前", systemImage: "arrow.up").tag(true)
      }
    } label: {
      SearchChipLabel(text: filter.oldestFirst ? "最早在前" : "最新在前", icon: "arrow.up.arrow.down", on: filter.oldestFirst, menu: true)
    }
  }

  private func chip(_ text: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) { SearchChipLabel(text: text, icon: icon, on: on, menu: false) }
      .buttonStyle(.plain)
  }
}

struct SearchChipLabel: View {
  let text: String
  let icon: String
  let on: Bool
  let menu: Bool

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon).imageScale(.small)
      Text(text).lineLimit(1)
      if menu { Image(systemName: "chevron.down").imageScale(.small).font(.caption2.weight(.semibold)) }
    }
    .font(.subheadline)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .foregroundStyle(on ? Color.white : Color.primary)
    .background(Capsule().fill(on ? Color.accentColor : Color(uiColor: .secondarySystemFill)))
    .contentShape(Capsule())
  }
}

// MARK: - 选人

/// 发送者：会话里的查找列这个会话的人（群成员；私聊是对方和我），全局搜索列好友和我。可以直接输入号码。
struct SearchPeoplePicker: View {
  let session: Session
  let scope: SearchFilterScope
  @State var mode: MessageSearchFilter.Mode
  @State var selected: [SearchPerson]
  let onDone: (MessageSearchFilter.Mode, [SearchPerson]) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var candidates: [SearchPerson] = []
  @State private var query = ""
  @State private var loading = true

  init(session: Session, scope: SearchFilterScope, mode: MessageSearchFilter.Mode, selected: [SearchPerson],
       onDone: @escaping (MessageSearchFilter.Mode, [SearchPerson]) -> Void) {
    self.session = session
    self.scope = scope
    _mode = State(initialValue: mode)
    _selected = State(initialValue: selected)
    self.onDone = onDone
  }

  private var shown: [SearchPerson] {
    let q = query.trimmingCharacters(in: .whitespaces)
    let chosen = Set(selected.map(\.id))
    let rest = candidates.filter { !chosen.contains($0.id) }
    guard !q.isEmpty else { return rest }
    var hits = rest.filter { $0.name.localizedCaseInsensitiveContains(q) || String($0.id).contains(q) }
    if let number = Int64(q), number > 10000, !chosen.contains(number), !hits.contains(where: { $0.id == number }) {
      hits.insert(SearchPerson(id: number, name: String(number)), at: 0)
    }
    return hits
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("", selection: $mode) {
            Text("只看").tag(MessageSearchFilter.Mode.only)
            Text("排除").tag(MessageSearchFilter.Mode.exclude)
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
        if !selected.isEmpty {
          Section {
            ForEach(selected) { p in row(p, on: true) }
          }
        }
        Section {
          ForEach(shown) { p in row(p, on: false) }
        }
      }
      .overlay { if loading && candidates.isEmpty { ProgressView() } }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "名字或号码")
      .navigationTitle("发送者")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { onDone(mode, selected); dismiss() }
        }
      }
    }
    .task { await load() }
  }

  private func row(_ p: SearchPerson, on: Bool) -> some View {
    Button {
      if on { selected.removeAll { $0.id == p.id } } else { selected.append(p) }
    } label: {
      HStack(spacing: 12) {
        AvatarView(sha256: nil, title: p.name, seed: p.id, size: 32)
        Text(p.name).lineLimit(1).foregroundStyle(.primary)
        Spacer()
        if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func load() async {
    defer { loading = false }
    switch scope {
    case .chat(let chatId):
      guard let d = try? session.store.dialog(chatId: chatId) else { return }
      let me = (try? session.store.selfUin(qqAccountId: d.qqAccountID)) ?? 0
      var list: [SearchPerson] = me != 0 ? [SearchPerson(id: me, name: "我")] : []
      if d.scene == .group {
        var req = Qqbridge_V1_ListGroupMembersRequest()
        req.groupID = d.peerID
        req.limit = 2000
        let members = (try? await session.api.contacts.listGroupMembers(request: req, headers: session.api.headers).get().members) ?? []
        list += members.filter { $0.userID != me }.map { m in
          SearchPerson(id: m.userID, name: !m.card.isEmpty ? m.card : (!m.nickname.isEmpty ? m.nickname : String(m.userID)))
        }
      } else {
        let name = (try? session.store.userName(qqAccountId: d.qqAccountID, userId: d.peerID)) ?? String(d.peerID)
        list.append(SearchPerson(id: d.peerID, name: name))
      }
      candidates = list
    case .global:
      let friends = (try? session.store.peers(kind: .user, friendsOnly: true)) ?? []
      let me = (try? session.store.dialogItems(limit: 1).first).flatMap { item in try? session.store.selfUin(qqAccountId: item.dialog.qqAccountID) } ?? 0
      candidates = (me != 0 ? [SearchPerson(id: me, name: "我")] : [])
        + friends.map { SearchPerson(id: $0.peerID, name: !$0.remark.isEmpty ? $0.remark : (!$0.name.isEmpty ? $0.name : String($0.peerID))) }
    }
  }
}

// MARK: - 选会话

struct SearchChatsPicker: View {
  let session: Session
  @State var mode: MessageSearchFilter.Mode
  @State var selected: [SearchChat]
  let onDone: (MessageSearchFilter.Mode, [SearchChat]) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var dialogs: [DialogItem] = []
  @State private var query = ""

  init(session: Session, mode: MessageSearchFilter.Mode, selected: [SearchChat],
       onDone: @escaping (MessageSearchFilter.Mode, [SearchChat]) -> Void) {
    self.session = session
    _mode = State(initialValue: mode)
    _selected = State(initialValue: selected)
    self.onDone = onDone
  }

  private var shown: [DialogItem] {
    let chosen = Set(selected.map(\.id))
    let q = query.trimmingCharacters(in: .whitespaces)
    return dialogs.filter { d in
      !chosen.contains(d.id) && (q.isEmpty || d.title.localizedCaseInsensitiveContains(q) || String(d.dialog.peerID).contains(q))
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Picker("", selection: $mode) {
            Text("只搜").tag(MessageSearchFilter.Mode.only)
            Text("排除").tag(MessageSearchFilter.Mode.exclude)
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
        if !selected.isEmpty {
          Section {
            ForEach(selected) { c in
              row(title: c.name, avatar: dialogs.first { $0.id == c.id }?.peer?.avatarSha256, seed: c.id, on: true) {
                selected.removeAll { $0.id == c.id }
              }
            }
          }
        }
        Section {
          ForEach(shown.prefix(200)) { d in
            row(title: d.title, avatar: d.peer?.avatarSha256, seed: d.dialog.peerID, on: false) {
              selected.append(SearchChat(id: d.id, name: d.title))
            }
          }
        }
      }
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "会话名或号码")
      .navigationTitle("会话")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("完成") { onDone(mode, selected); dismiss() } }
      }
    }
    .task { dialogs = (try? session.store.dialogItems(limit: 5000)) ?? [] }
  }

  private func row(title: String, avatar: String?, seed: Int64, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        AvatarView(sha256: avatar, title: title, seed: seed, size: 32)
        Text(title).lineLimit(1).foregroundStyle(.primary)
        Spacer()
        if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - 时间范围

struct SearchDatePicker: View {
  let onDone: (Date?, Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var since: Date
  @State private var until: Date
  @State private var hasSince: Bool
  @State private var hasUntil: Bool

  init(since: Date?, until: Date?, onDone: @escaping (Date?, Date?) -> Void) {
    self.onDone = onDone
    let today = Calendar.current.startOfDay(for: Date())
    _since = State(initialValue: since ?? Calendar.current.date(byAdding: .day, value: -6, to: today)!)
    _until = State(initialValue: until ?? today)
    _hasSince = State(initialValue: since != nil)
    _hasUntil = State(initialValue: until != nil)
  }

  private enum Preset: String, CaseIterable, Identifiable {
    case today = "今天", week = "最近 7 天", month = "最近 30 天", year = "今年"
    var id: String { rawValue }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(Preset.allCases) { p in
            Button(p.rawValue) { apply(p) }
          }
        }
        Section {
          Toggle("开始", isOn: $hasSince.animation())
          if hasSince { DatePicker("开始", selection: $since, in: ...until, displayedComponents: .date).datePickerStyle(.graphical) }
          Toggle("结束", isOn: $hasUntil.animation())
          if hasUntil { DatePicker("结束", selection: $until, in: since..., displayedComponents: .date).datePickerStyle(.graphical) }
        }
        if hasSince || hasUntil {
          Section { Button("不限时间", role: .destructive) { onDone(nil, nil); dismiss() } }
        }
      }
      .navigationTitle("时间")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { onDone(hasSince ? since : nil, hasUntil ? until : nil); dismiss() }
        }
      }
    }
  }

  private func apply(_ p: Preset) {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let start: Date
    switch p {
    case .today: start = today
    case .week: start = calendar.date(byAdding: .day, value: -6, to: today)!
    case .month: start = calendar.date(byAdding: .day, value: -29, to: today)!
    case .year: start = calendar.date(from: calendar.dateComponents([.year], from: today))!
    }
    onDone(start, today)
    dismiss()
  }
}
