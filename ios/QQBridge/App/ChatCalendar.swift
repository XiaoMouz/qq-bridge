// 聊天日历：点聊天页顶部的日期徽章弹出（和 Telegram 一样），按月列出有消息的日子，有图片的日子用那天的一张图当底，
// 其余按当天条数深浅着色（热度）。点一天在底下看 24 小时的分布，点某个小时或「跳转」回到聊天里那个时刻。
// 2026-11-08 用户要求；数据来自服务端 GetChatCalendar（每天、每小时条数和一张图，缓存 10 分钟），跳转用 FindMessageByTime。
import QQBridgeKit
import QQBridgeProto
import SwiftUI

@MainActor @Observable
final class ChatCalendarModel {
  struct Day: Identifiable {
    /// 当地这天 0 点（unix 秒）。
    let id: Int64
    let count: Int
    let hours: [Int]
    let preview: String?
  }

  struct Month: Identifiable {
    /// 这个月 1 号 0 点。
    let id: Date
    /// 1 号之前空几格（周一开头）。
    let leading: Int
    let days: Int
  }

  private(set) var days: [Int64: Day] = [:]
  private(set) var months: [Month] = []
  private(set) var maxCount = 1
  private(set) var loading = true
  private(set) var error: String?

  /// 同一个会话在这次运行里只拉一次（服务端另有 10 分钟缓存）。
  private static var cache: [Int64: (at: Date, days: [Day])] = [:]

  func load(session: Session, chatId: Int64) async {
    if let hit = Self.cache[chatId], Date().timeIntervalSince(hit.at) < 600 { apply(hit.days); return }
    loading = true
    error = nil
    defer { loading = false }
    var req = Qqbridge_V1_GetChatCalendarRequest()
    req.chatID = chatId
    req.utcOffsetMinutes = Int32(TimeZone.current.secondsFromGMT() / 60)
    do {
      let res = try await session.api.messages.getChatCalendar(request: req, headers: session.api.headers).get()
      let list = res.days.map { Day(id: $0.day, count: Int($0.count), hours: $0.hours.map(Int.init), preview: $0.previewSha256.isEmpty ? nil : $0.previewSha256) }
      Self.cache[chatId] = (Date(), list)
      apply(list)
    } catch {
      self.error = LoadState.describe(error)
    }
  }

  private func apply(_ list: [Day]) {
    days = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    maxCount = max(1, list.map(\.count).max() ?? 1)
    var calendar = Calendar.current
    calendar.firstWeekday = 2
    let now = Date()
    let first = list.first.map { Date(timeIntervalSince1970: TimeInterval($0.id)) } ?? now
    var month = calendar.date(from: calendar.dateComponents([.year, .month], from: first))!
    let last = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
    var out: [Month] = []
    while month <= last {
      let weekday = calendar.component(.weekday, from: month)
      let leading = (weekday - calendar.firstWeekday + 7) % 7
      let count = calendar.range(of: .day, in: .month, for: month)!.count
      out.append(Month(id: month, leading: leading, days: count))
      month = calendar.date(byAdding: .month, value: 1, to: month)!
    }
    months = out
  }

  func day(_ date: Date) -> Day? { days[Int64(Calendar.current.startOfDay(for: date).timeIntervalSince1970)] }

  /// 0…1：按对数算，几条和几千条的日子都分得出深浅。
  func heat(_ count: Int) -> Double {
    guard count > 0 else { return 0 }
    return min(1, log(Double(count) + 1) / log(Double(maxCount) + 1))
  }
}

struct ChatCalendarSheet: View {
  let session: Session
  let chatId: Int64
  /// 打开时停在哪天所在的月（聊天里正在看的那天）。
  let initial: Date
  /// 跳到这个时刻（unix 秒）。
  let onJump: (Int64) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var model = ChatCalendarModel()
  @State private var selected: ChatCalendarModel.Day?

  private static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 18, pinnedViews: .sectionHeaders) {
            ForEach(model.months) { month in
              Section {
                monthGrid(month)
              } header: {
                monthHeader(month.id)
              }
              .id(month.id)
            }
          }
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: model.months.count) { _, _ in scrollToInitial(proxy) }
        .onAppear { scrollToInitial(proxy) }
      }
      .overlay {
        if model.loading && model.months.isEmpty { ProgressView() }
        else if let error = model.error, model.months.isEmpty {
          ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) { weekdayRow }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let selected { DayDetail(day: selected, onJump: jump) }
      }
      .animation(.snappy, value: selected?.id)
      .navigationTitle("跳到日期")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
    }
    .presentationDetents([.large])
    .task { await model.load(session: session, chatId: chatId) }
  }

  private func scrollToInitial(_ proxy: ScrollViewProxy) {
    let cal = Calendar.current
    guard let month = cal.date(from: cal.dateComponents([.year, .month], from: initial)),
          model.months.contains(where: { $0.id == month }) else { return }
    proxy.scrollTo(month, anchor: .center)
    if selected == nil { selected = model.day(initial) }
  }

  private var weekdayRow: some View {
    HStack(spacing: 0) {
      ForEach(Self.weekdays, id: \.self) { d in
        Text(d).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func monthHeader(_ month: Date) -> some View {
    Text(month.formatted(.dateTime.year().month(.wide).locale(Locale(identifier: "zh_CN"))))
      .font(.subheadline.weight(.semibold))
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .glassEffect(.regular, in: Capsule())
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
  }

  private func monthGrid(_ month: ChatCalendarModel.Month) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
      ForEach(0..<month.leading, id: \.self) { i in Color.clear.frame(height: 1).id("pad\(i)") }
      ForEach(1...month.days, id: \.self) { n in
        let date = Calendar.current.date(byAdding: .day, value: n - 1, to: month.id)!
        DayCell(number: n, day: model.day(date), heat: model.heat(model.day(date)?.count ?? 0),
                selected: selected?.id == model.day(date)?.id && selected != nil,
                isToday: Calendar.current.isDateInToday(date)) {
          if let d = model.day(date) { selected = d }
        }
      }
    }
  }

  private func jump(_ unix: Int64) {
    dismiss()
    onJump(unix)
  }
}

private struct DayCell: View {
  let number: Int
  let day: ChatCalendarModel.Day?
  let heat: Double
  let selected: Bool
  let isToday: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        // 没消息的日子也占满一格（只有文字时会被压扁成「…」）。
        Circle().fill(Color.clear)
        background
        Text("\(number)")
          .font(.callout.weight(day == nil ? .regular : .semibold).monospacedDigit())
          .foregroundStyle(foreground)
          .shadow(color: day?.preview != nil ? .black.opacity(0.6) : .clear, radius: 2)
      }
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 3) }
        else if isToday { Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5) }
      }
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(day == nil)
    .accessibilityLabel(day.map { "\(number) 日，\($0.count) 条" } ?? "\(number) 日")
  }

  @ViewBuilder private var background: some View {
    if let preview = day?.preview {
      CachedImage(sha256: preview, maxPixel: 160) { Circle().fill(Color.accentColor.opacity(0.15 + 0.5 * heat)) }
        .aspectRatio(contentMode: .fill)
        .clipShape(Circle())
        .overlay(Circle().fill(.black.opacity(0.2)))
    } else if day != nil {
      Circle().fill(Color.accentColor.opacity(0.1 + 0.55 * heat))
    }
  }

  private var foreground: Color {
    guard let day else { return Color(uiColor: .tertiaryLabel) }
    if day.preview != nil || heat > 0.7 { return .white }
    return .primary
  }
}

/// 选中的那天：条数、24 小时分布（点某个小时跳过去）、跳到这天的开头。
private struct DayDetail: View {
  let day: ChatCalendarModel.Day
  let onJump: (Int64) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(Date(timeIntervalSince1970: TimeInterval(day.id)).formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))
          .font(.headline)
        Text("\(day.count) 条").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        Button("跳转") { onJump(firstActiveHour) }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
      }
      HourBars(hours: day.hours) { hour in onJump(day.id + Int64(hour) * 3600) }
    }
    .padding(16)
    .glassEffect(.regular, in: .rect(cornerRadius: 24))
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  /// 「跳转」到这天第一条消息所在的小时（FindMessageByTime 从这个时刻往后找第一条）。
  private var firstActiveHour: Int64 {
    let hour = day.hours.firstIndex { $0 > 0 } ?? 0
    return day.id + Int64(hour) * 3600
  }
}

private struct HourBars: View {
  let hours: [Int]
  let onTap: (Int) -> Void

  var body: some View {
    let peak = max(1, hours.max() ?? 1)
    VStack(spacing: 4) {
      HStack(alignment: .bottom, spacing: 2) {
        ForEach(0..<24, id: \.self) { h in
          let n = h < hours.count ? hours[h] : 0
          Button { onTap(h) } label: {
            VStack {
              Spacer(minLength: 0)
              RoundedRectangle(cornerRadius: 2)
                .fill(n > 0 ? Color.accentColor.opacity(0.35 + 0.65 * Double(n) / Double(peak)) : Color.secondary.opacity(0.2))
                .frame(height: n > 0 ? max(4, 44 * CGFloat(n) / CGFloat(peak)) : 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(n == 0)
          .accessibilityLabel("\(h) 点，\(n) 条")
        }
      }
      HStack {
        ForEach([0, 6, 12, 18], id: \.self) { h in
          Text("\(h)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}
