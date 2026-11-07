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

  /// 筛选（发送者、会话、时间、类型、排序）；改了之后由界面重新 search。
  var filter = MessageSearchFilter()
  /// 上一次真正查的筛选（结果对应的那一份）。
  private(set) var searchedFilter = MessageSearchFilter()

  @ObservationIgnored private let session: Session
  /// 0 = 全部会话。
  let chatId: Int64
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var seen = Set<String>()

  init(session: Session, chatId: Int64 = 0) {
    self.session = session
    self.chatId = chatId
  }

  /// 能不能搜：有关键词，或者在限定的会话里有筛选条件（服务端不带关键词时只在指定会话里查）。
  func canSearch(_ query: String) -> Bool {
    !query.trimmingCharacters(in: .whitespaces).isEmpty || filter.allowsEmptyQuery(chatId: chatId)
  }

  /// 结果是不是这次的关键词和筛选查出来的。
  func isCurrent(_ query: String) -> Bool {
    searched == query.trimmingCharacters(in: .whitespaces) && searchedFilter == filter
  }

  func search(_ query: String) async {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard canSearch(q) else { return reset() }
    let used = filter
    generation += 1
    let request = generation
    searching = true
    failed = nil
    defer { if request == generation { searching = false } }
    do {
      let page = try await fetch(q, filter: used, before: nil)
      guard request == generation else { return }
      results = page.messages
      seen = Set(page.messages.map(\.searchKey))
      next = page.hasNext ? page.next : nil
      searched = q
      searchedFilter = used
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
      let page = try await fetch(q, filter: searchedFilter, before: cursor)
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
    searchedFilter = MessageSearchFilter()
  }

  private func fetch(_ q: String, filter: MessageSearchFilter, before: Qqbridge_V1_SearchCursor?) async throws -> Qqbridge_V1_SearchMessagesResponse {
    var req = Qqbridge_V1_SearchMessagesRequest()
    req.query = q
    filter.apply(to: &req)
    req.chatID = chatId
    req.limit = 100
    if let before { req.before = before }
    return try await session.api.messages.searchMessages(request: req, headers: session.api.headers).get()
  }

  /// 结果里显示的发送人：自己的显示「我」，群里优先群名片（消息里带的），再退到本地资料的名字和号码。
  func senderName(_ m: Qqbridge_V1_Message) -> String { Self.senderName(m, session: session) }

  /// Mac 侧栏搜索也用这一份（同一套「我 / 群名片 / 本地名字 / 号码」顺序）。
  static func senderName(_ m: Qqbridge_V1_Message, session: Session) -> String {
    // 灰色提示没有发送者（号码是 0）。
    if m.kind == .service { return "提示" }
    guard let d = try? session.store.dialog(chatId: m.chatID) else {
      return !m.senderName.isEmpty ? m.senderName : String(m.senderID)
    }
    if m.senderID == (try? session.store.selfUin(qqAccountId: d.qqAccountID)) { return "我" }
    if !m.senderName.isEmpty { return m.senderName }
    return (try? session.store.userName(qqAccountId: d.qqAccountID, userId: m.senderID)) ?? String(m.senderID)
  }
}

/// 会话里的查找：搜索页和聊天页共用（结果列表、聊天页底部的上一条 / 下一条）。
@MainActor @Observable
final class ChatSearchSession {
  let pager: MessageSearchPager
  var query = ""
  /// 正在聊天里看的那条结果（searchKey）；列表回来时滚到它。
  var current: String?
  /// 聊天页显示「上一条 / 下一条」。
  var navigating = false

  init(pager: MessageSearchPager) { self.pager = pager }

  var currentIndex: Int? { current.flatMap { key in pager.results.firstIndex { $0.searchKey == key } } }

  /// 往更早（older = true）或更新的一条；到了已加载结果的尽头先翻下一页。返回要跳的消息。
  func step(older: Bool) async -> Qqbridge_V1_Message? {
    guard let i = currentIndex else { return nil }
    // 列表默认最新在前：更早 = 往后；选了最早在前则相反。
    let forward = older != pager.searchedFilter.oldestFirst
    let j = forward ? i + 1 : i - 1
    if forward, j >= pager.results.count, pager.hasMore { await pager.loadMore() }
    guard pager.results.indices.contains(j) else { return nil }
    let m = pager.results[j]
    current = m.searchKey
    return m
  }

  func canStep(older: Bool) -> Bool {
    guard let i = currentIndex else { return false }
    let forward = older != pager.searchedFilter.oldestFirst
    return forward ? (i + 1 < pager.results.count || pager.hasMore) : i > 0
  }
}
