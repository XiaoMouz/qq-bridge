import QQBridgeKit
import QQBridgeProto
import SwiftUI

struct DialogListView: View {
  let session: Session
  @Environment(AppModel.self) private var model
  @State private var items: [DialogItem] = []
  @State private var path: [Int64] = []

  var body: some View {
    NavigationStack(path: $path) {
      List(items) { item in
        NavigationLink(value: item.id) {
          DialogRow(item: item, typing: model.isTyping(item.id))
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(item.dialog.pinned ? Color.secondary.opacity(0.08) : nil)
      }
      .listStyle(.plain)
      .navigationTitle("消息")
      .navigationDestination(for: Int64.self) { chatId in
        ChatScreen(session: session, chatId: chatId)
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
        for try await list in session.store.observeDialogs() { items = list }
      } catch {}
    }
  }
}

struct DialogRow: View {
  let item: DialogItem
  let typing: Bool

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(sha256: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(item.title).font(.body.weight(.semibold)).lineLimit(1)
          if item.dialog.notifyPolicy == "muted" {
            Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Text(Format.listTime(item.dialog.topTime)).font(.caption).foregroundStyle(.secondary)
        }
        HStack(alignment: .firstTextBaseline) {
          preview.font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
          Spacer(minLength: 8)
          badge
        }
      }
    }
  }

  @ViewBuilder private var preview: some View {
    if typing {
      Text("正在输入…").foregroundStyle(.tint)
    } else if !item.dialog.draft.segments.isEmpty {
      Text("[草稿] ").foregroundStyle(.red) + Text(item.dialog.draft.segments.map(\.text).joined())
    } else {
      Text(Format.preview(item.dialog.topMessage))
    }
  }

  @ViewBuilder private var badge: some View {
    let d = item.dialog
    if d.unreadMentions > 0 {
      Text("@").font(.caption.bold()).padding(6).background(.tint, in: Circle()).foregroundStyle(.white)
    } else if d.unreadCount > 0 {
      Text(d.unreadCount > 99 ? "99+" : "\(d.unreadCount)")
        .font(.caption.bold().monospacedDigit())
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(d.notifyPolicy == "muted" ? Color.secondary : Color.accentColor, in: Capsule())
        .foregroundStyle(.white)
    }
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
    if m.state == .recalled { return "[消息已撤回]" }
    if !m.text.isEmpty { return m.text }
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
