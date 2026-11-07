// 存储页里某一类内容（图片、视频、文件、语音……）的排序和发送者：按大小 / 按日期（按天分组）/ 按发送者（列出各人占用，
// 点一个人只看他的），群里还可以只看或排除某些人。2026-11-08 用户要求；iOS 的 StorageItemsView 和 Mac 的
// MacStorageItemsView 共用。数据来自服务端 ListStorageItems（sort、sender_ids）和 ListStorageSenders，本机缓存只能按大小。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

enum StorageSort: String, CaseIterable, Identifiable, Sendable {
  case size, newest, oldest, sender
  var id: String { rawValue }
  var title: String {
    switch self {
    case .size: "按大小"
    case .newest: "最新在前"
    case .oldest: "最早在前"
    case .sender: "按发送者"
    }
  }
  var icon: String {
    switch self {
    case .size: "arrow.down.circle"
    case .newest: "calendar"
    case .oldest: "calendar.badge.clock"
    case .sender: "person.2"
    }
  }
  /// ListStorageItems 的 sort（按发送者时列表本身按大小）。
  var api: String {
    switch self {
    case .newest: "time_desc"
    case .oldest: "time_asc"
    default: "size"
    }
  }
  var byDate: Bool { self == .newest || self == .oldest }
}

struct StorageItemsQuery: Equatable, Sendable {
  var sort = StorageSort.size
  var senderMode = MessageSearchFilter.Mode.only
  var senders: [SearchPerson] = []

  func apply(to req: inout Qqbridge_V1_ListStorageItemsRequest) {
    req.sort = sort.api
    let ids = senders.map(\.id)
    if senderMode == .only { req.senderIds = ids } else { req.excludeSenderIds = ids }
  }

  var sendersLabel: String? {
    guard let first = senders.first else { return nil }
    let names = senders.count == 1 ? first.name : "\(first.name) 等 \(senders.count) 人"
    return senderMode == .exclude ? "排除 \(names)" : names
  }
}

/// 按天分组（按日期排序时）；其余情况一组。
struct StorageItemSection: Identifiable {
  let id: String
  let title: String?
  let items: [StorageItemModel]
  var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum StorageSections {
  static func make(_ items: [StorageItemModel], sort: StorageSort) -> [StorageItemSection] {
    guard sort.byDate else { return [StorageItemSection(id: "all", title: nil, items: items)] }
    var out: [StorageItemSection] = []
    var current: (day: Date, items: [StorageItemModel])?
    let calendar = Calendar.current
    for item in items {
      let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(item.time)))
      if current?.day == day { current!.items.append(item); continue }
      if let c = current { out.append(section(c.day, c.items)) }
      current = (day, [item])
    }
    if let c = current { out.append(section(c.day, c.items)) }
    return out
  }

  private static func section(_ day: Date, _ items: [StorageItemModel]) -> StorageItemSection {
    let year = Calendar.current.component(.year, from: Date())
    let style: Date.FormatStyle = Calendar.current.component(.year, from: day) == year
      ? .dateTime.month().day().weekday(.abbreviated) : .dateTime.year().month().day()
    let title = items.first?.time == 0 ? "时间未知" : day.formatted(style.locale(Locale(identifier: "zh_CN")))
    return StorageItemSection(id: "\(Int(day.timeIntervalSince1970))", title: title, items: items)
  }
}

/// 网格上方的一排：排序菜单，群里加发送者筛选。
struct StorageQueryBar: View {
  @Binding var query: StorageItemsQuery
  /// 群聊（服务端）才有发送者。
  let session: Session
  let chatId: Int64?
  let showsSenders: Bool
  @State private var pickingSenders = false

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        Menu {
          Picker("排序", selection: $query.sort) {
            ForEach(StorageSort.allCases.filter { showsSenders || $0 != .sender }) { s in
              Label(s.title, systemImage: s.icon).tag(s)
            }
          }
        } label: {
          SearchChipLabel(text: query.sort.title, icon: query.sort.icon, on: query.sort != .size, menu: true)
        }
        if showsSenders {
          Button { pickingSenders = true } label: {
            SearchChipLabel(text: query.sendersLabel ?? "发送者", icon: "person", on: !query.senders.isEmpty, menu: false)
          }
          .buttonStyle(.plain)
        }
        if query != StorageItemsQuery() {
          Button("清除", systemImage: "xmark.circle.fill") { query = StorageItemsQuery() }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
    }
    .sheet(isPresented: $pickingSenders) {
      if let chatId {
        SearchPeoplePicker(session: session, scope: .chat(chatId), mode: query.senderMode, selected: query.senders) { mode, people in
          query.senderMode = mode
          query.senders = people
        }
      }
    }
  }
}

/// 「按发送者」：各人占了多少（服务端 ListStorageSenders），点一个人只看他的。
struct StorageSendersList: View {
  let session: Session
  let chatId: Int64
  let group: StorageGroup
  let onPick: (SearchPerson) -> Void
  @State private var senders: [Qqbridge_V1_StorageSender] = []
  @State private var loading = true
  @State private var error: String?
  @State private var names: [Int64: String] = [:]
  @State private var avatars = AvatarBook()

  var body: some View {
    let peak = max(1, senders.map { Int64($0.bytes) }.max() ?? 1)
    LazyVStack(spacing: 0) {
      ForEach(senders, id: \.senderID) { s in
        let name = displayName(s)
        Button { onPick(SearchPerson(id: s.senderID, name: name)) } label: {
          HStack(spacing: 12) {
            AvatarView(sha256: avatars.sha256[s.senderID], title: name, seed: s.senderID, size: 36)
              .onAppear { avatars.want(s.senderID, session: session) }
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(name).lineLimit(1)
                Spacer()
                Text(Bytes.text(Int64(s.bytes))).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
              }
              GeometryReader { geo in
                Capsule().fill(group.color.opacity(0.8))
                  .frame(width: max(3, geo.size.width * CGFloat(Double(s.bytes) / Double(peak))))
              }
              .frame(height: 4)
              Text("\(s.count) 份").font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .overlay {
      if loading && senders.isEmpty { ProgressView().padding(.top, 40) }
      else if let error, senders.isEmpty { Text(error).foregroundStyle(.secondary).padding(.top, 40) }
    }
    .task { await load() }
  }

  private func displayName(_ s: Qqbridge_V1_StorageSender) -> String {
    if let n = names[s.senderID] { return n }
    return s.name.isEmpty ? String(s.senderID) : s.name
  }

  private func load() async {
    defer { loading = false }
    var req = Qqbridge_V1_ListStorageSendersRequest()
    req.chatID = chatId
    req.categories = group.serverCategories
    do {
      senders = try await session.api.media.listStorageSenders(request: req, headers: session.api.headers).get().senders
      // 自己显示「我」，其余优先本地资料里的名字（备注）。
      if let d = try? session.store.dialog(chatId: chatId) {
        let me = (try? session.store.selfUin(qqAccountId: d.qqAccountID)) ?? 0
        var map: [Int64: String] = [:]
        for s in senders {
          if s.senderID == me { map[s.senderID] = "我" }
          else if s.name.isEmpty, let n = try? session.store.userName(qqAccountId: d.qqAccountID, userId: s.senderID) { map[s.senderID] = n }
        }
        names = map
      }
    } catch {
      self.error = LoadState.describe(error)
    }
  }
}

/// 按天分组时的组头：日期、份数和大小。
struct StorageSectionHeader: View {
  let section: StorageItemSection

  var body: some View {
    if let title = section.title {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.subheadline.weight(.semibold))
        Spacer()
        Text("\(section.items.count) 份 · \(Bytes.text(section.bytes))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 2)
    }
  }
}
