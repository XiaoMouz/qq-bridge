// 聊天记录的服务端全文搜索：首页搜索和会话里的「查找聊天记录」共用。
// 服务端每页最多 100 条，按 (time, chat_id, seq) 游标往更早翻；以前只取第一页，再早的搜不到。
import Observation
import QQBridgeKit
import QQBridgeProto

@MainActor @Observable
final class MessageSearchPager {
  private(set) var results: [Qqbridge_V1_Message] = []
  /// 上一次真正查过的关键词（还没按搜索时不显示"未找到"）。
  private(set) var searched: String?
  private(set) var searching = false
  private(set) var loadingMore = false
  private(set) var failed: String?
  private(set) var next: Qqbridge_V1_SearchCursor?
  var hasMore: Bool { next != nil }

  @ObservationIgnored private let session: Session
  /// 0 = 全部会话。
  @ObservationIgnored private let chatId: Int64
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var seen = Set<String>()

  init(session: Session, chatId: Int64 = 0) {
    self.session = session
    self.chatId = chatId
  }

  func search(_ query: String) async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return reset() }
    generation += 1
    let request = generation
    searching = true
    failed = nil
    defer { if request == generation { searching = false } }
    do {
      let page = try await fetch(q, before: nil)
      guard request == generation else { return }
      results = page.messages
      seen = Set(page.messages.map(\.searchKey))
      next = page.hasNext ? page.next : nil
      searched = q
    } catch {
      guard request == generation else { return }
      results = []
      next = nil
      failed = LoadState.describe(error)
    }
  }

  /// 列表滚到最后一条时调用。
  func loadMore() async {
    guard let q = searched, let cursor = next, !loadingMore, !searching else { return }
    let request = generation
    loadingMore = true
    defer { if request == generation { loadingMore = false } }
    do {
      let page = try await fetch(q, before: cursor)
      guard request == generation else { return }
      let fresh = page.messages.filter { seen.insert($0.searchKey).inserted }
      results += fresh
      next = page.hasNext && !page.messages.isEmpty ? page.next : nil
    } catch {
      // 翻页失败不清空已有结果；保留游标，下次滚到底再试。
      guard request == generation else { return }
      failed = LoadState.describe(error)
    }
  }

  func reset() {
    generation += 1
    results = []
    searched = nil
    searching = false
    loadingMore = false
    failed = nil
    next = nil
    seen = []
  }

  private func fetch(_ q: String, before: Qqbridge_V1_SearchCursor?) async throws -> Qqbridge_V1_SearchMessagesResponse {
    var req = Qqbridge_V1_SearchMessagesRequest()
    req.query = q
    req.chatID = chatId
    req.limit = 100
    if let before { req.before = before }
    return try await session.api.messages.searchMessages(request: req, headers: session.api.headers).get()
  }

  /// 结果里显示的发送人：自己的显示「我」，群里优先群名片（消息里带的），再退到本地资料的名字和号码。
  func senderName(_ m: Qqbridge_V1_Message) -> String {
    guard let d = try? session.store.dialog(chatId: m.chatID) else {
      return !m.senderName.isEmpty ? m.senderName : String(m.senderID)
    }
    if m.senderID == (try? session.store.selfUin(qqAccountId: d.qqAccountID)) { return "我" }
    if !m.senderName.isEmpty { return m.senderName }
    return (try? session.store.userName(qqAccountId: d.qqAccountID, userId: m.senderID)) ?? String(m.senderID)
  }
}
