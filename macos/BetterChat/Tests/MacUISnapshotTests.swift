// 2026-11-08：在 Mac 测试宿主的真实窗口里（Mac idiom）渲染这次新加的界面，存成 PNG 人工检查：
// 搜索筛选条、会话内查找、存储页排序 / 按天分组、聊天日历、视频下载进度。不连服务端（会话指向不存在的地址）。
// 图片写到临时目录，路径打印在测试输出里（「快照：」开头）。
import Foundation
@testable import QQBridgeKit
import QQBridgeProto
import SwiftUI
import Testing
import UIKit
@testable import BetterChat

@MainActor private final class SnapshotStoragePages: MacStorageItemsService {
  let items: [StorageItemModel]
  init(items: [StorageItemModel]) { self.items = items }
  func page(offset: UInt32, query: StorageItemsQuery) async throws -> MacStorageItemsPage {
    MacStorageItemsPage(items: offset == 0 ? items : [], more: false)
  }
}

@Suite(.serialized) @MainActor
struct MacUISnapshotTests {
  private static let dir: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("betterchat-mac-ui", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  private func session() throws -> Session {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    return try Session(config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:9")!), token: "test", container: container)
  }

  /// 放进测试宿主的窗口里布局、等一会儿（异步加载、动画），再连同子视图一起画成图片。
  private func snapshot(_ name: String, size: CGSize, wait: Duration = .milliseconds(800), @ViewBuilder _ content: () -> some View) async throws -> UIImage {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: AnyView(content().environment(AppModel.shared)))
    window.rootViewController = host
    window.isHidden = false
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
    try await Task.sleep(for: wait)
    host.view.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let url = Self.dir.appendingPathComponent("\(name).png")
    try image.pngData()?.write(to: url)
    print("快照：\(url.path)")
    window.isHidden = true
    window.rootViewController = nil
    return image
  }

  private func storageItem(_ n: Int, daysAgo: Int, size: UInt64) -> StorageItemModel {
    var raw = Qqbridge_V1_StorageItem()
    raw.sha256 = String(repeating: String(n % 10), count: 64)
    raw.size = size
    raw.category = "video"
    raw.state = "present"
    raw.time = Int64(Date().timeIntervalSince1970) - Int64(daysAgo) * 86400
    raw.chatID = 7
    raw.seq = Int64(100 + n)
    raw.senderID = Int64(1000 + n % 3)
    return StorageItemModel(server: raw)
  }

  @Test func searchFilterBarShowsChosenFilters() async throws {
    let session = try session()
    var filter = MessageSearchFilter()
    filter.peopleMode = .exclude
    filter.people = [SearchPerson(id: 1, name: "张三"), SearchPerson(id: 2, name: "李四")]
    filter.chats = [SearchChat(id: 3, name: "Something")]
    filter.since = Calendar.current.date(byAdding: .day, value: -6, to: Date())
    filter.until = Date()
    filter.kinds = [.photo, .video]
    let image = try await snapshot("search-filter-bar", size: CGSize(width: 900, height: 80)) {
      SearchFilterBar(filter: .constant(filter), scope: .global, session: session).background(Color(uiColor: .systemBackground))
    }
    #expect(image.size.width == 900)
    #expect(filter.peopleLabel == "排除 张三 等 2 人" && filter.kindsLabel == "图片、视频")
  }

  @Test func chatHistoryWithFilters() async throws {
    let session = try session()
    _ = try await snapshot("chat-history", size: CGSize(width: 360, height: 520)) {
      NavigationStack { MacChatHistoryView(session: session, chatId: 7) }
    }
  }

  @Test func storageItemsByDateAndSenders() async throws {
    let session = try session()
    let items = (0..<7).map { storageItem($0, daysAgo: $0 / 3, size: UInt64(1_000_000 * (7 - $0))) }
    var byDate = StorageItemsQuery()
    byDate.sort = .newest
    byDate.senders = [SearchPerson(id: 1000, name: "诶嘿")]
    _ = try await snapshot("storage-items", size: CGSize(width: 700, height: 620), wait: .milliseconds(1200)) {
      NavigationStack {
        MacStorageItemsView(session: session, source: .server, group: .video, chatID: 7, title: "视频",
                            service: SnapshotStoragePages(items: items), query: byDate, showsSenders: true)
      }
      .environment(\.session, session)
    }
    let sections = StorageSections.make(items.sorted { $0.time > $1.time }, sort: .newest)
    #expect(sections.count == 3 && sections.allSatisfy { $0.title != nil })
  }

  @Test func chatCalendarWithHeatAndHours() async throws {
    let session = try session()
    let model = ChatCalendarModel()
    let today = Calendar.current.startOfDay(for: Date())
    let days = (0..<40).compactMap { i -> ChatCalendarModel.Day? in
      guard i % 4 != 3, let day = Calendar.current.date(byAdding: .day, value: -i, to: today) else { return nil }
      let hours = (0..<24).map { h in h < 8 ? 0 : (h * 37 + i * 11) % 60 }
      return ChatCalendarModel.Day(id: Int64(day.timeIntervalSince1970), count: hours.reduce(0, +) * (i % 5 + 1), hours: hours, preview: nil)
    }
    model.apply(days.reversed())
    _ = try await snapshot("chat-calendar", size: CGSize(width: 480, height: 760), wait: .milliseconds(1200)) {
      ChatCalendarSheet(session: session, chatId: 7, initial: Date(), model: model) { _ in }
    }
    #expect(model.months.count >= 2 && model.heat(model.maxCount) == 1)
  }

  @Test func videoDownloadProgress() async throws {
    let value = MediaProgress.Value(received: 42_000_000, total: 100_000_000, at: Date())
    _ = try await snapshot("video-progress", size: CGSize(width: 300, height: 200)) {
      ZStack { Color.black; VideoFetchProgress(fetching: true, value: value) }
    }
    #expect(value.fraction == 0.42)
  }

  private func dialog(_ id: Int64, _ name: String, unread: UInt32, mentions: UInt32 = 0, replies: UInt32 = 0, muted: Bool = false) -> DialogItem {
    var d = Qqbridge_V1_Dialog()
    d.chatID = id; d.peerID = id * 1000; d.unreadCount = unread
    d.unreadMentions = mentions; d.unreadReplies = replies
    d.notifyPolicy = muted ? "muted" : "default"
    var p = Qqbridge_V1_Peer(); p.name = name
    return DialogItem(dialog: d, peer: p)
  }

  /// 2026-11-09：收起后的窄栏，角标 @我 红、回复我 绿、免打扰灰、其余主题色；三位数显示 99+。
  @Test func sidebarRailWithColoredBadges() async throws {
    let items = [dialog(1, "Something", unread: 3, mentions: 1), dialog(2, "张三", unread: 1, replies: 1),
                 dialog(3, "李四", unread: 12), dialog(4, "大群", unread: 520, muted: true), dialog(5, "王五", unread: 0)]
    let actions = MacSidebarActions(selectContact: { _ in })
    _ = try await snapshot("sidebar-rail", size: CGSize(width: MacMetrics.railWidth, height: 560)) {
      VStack(spacing: 0) {
        MacSidebarRailHeader(section: .messages, showsArchived: false, archivedUnread: true, searching: false, actions: actions)
        ForEach(items) { MacRailDialogCell(item: $0).padding(.vertical, MacMetrics.railRowVerticalMargin) }
        Spacer()
        MacSidebarRailFooter(searching: false, openSearch: {})
      }
      .background(Color(uiColor: .secondarySystemBackground))
    }
    #expect(MacRailBadge.color(items[0].dialog, muted: false) == .red)
    #expect(MacRailBadge.color(items[1].dialog, muted: false) == .green)
    #expect(MacRailBadge.color(items[2].dialog, muted: false) == .accentColor)
  }

  @Test func searchPageEmptyState() async throws {
    let session = try session()
    let sidebar = MacSidebarViewModel()
    let dialogs = MacDialogsViewModel(service: MacSessionConversationService(session: session), manualSync: MacManualSync())
    let search = MacSidebarSearchViewModel(service: MacSessionSearchService(session: session), dialogs: dialogs)
    _ = try await snapshot("search-page", size: CGSize(width: 700, height: 420)) {
      NavigationStack { MacSearchPage(session: session, sidebar: sidebar, search: search) }
    }
  }
}
