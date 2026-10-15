// 同步引擎（docs/design.md 4.7 / 6.2）：连接、Subscribe 流、pts 与 chat_pts、补洞，都在这一个 actor 里串行处理。
// 规则（与服务端约定，见 sync.proto）：
// - 全局 pts（会话列表、资料、发件箱）：更新的 pts == 本地 + 1 → 应用；<= 本地 → 忽略；更大 → 等 0.5 秒后拉差量补齐。
// - 会话 chat_pts（消息、服务事件）：只跟踪本地已经加载过的会话（chat_pts > 0），规则同上，缺了就拉该会话的差量；
//   没加载过的会话靠会话列表里的最新一条消息显示预览，打开时再拉首屏。
// - 心跳带服务端当前 pts，落后就补；Resync 表示客户端跟不上，断开重拉。
// - 断线后按 1、2、4…30 秒退避重连，每次重连先用 GetDifference 追平再订阅。
// 数据一律写进 LocalStore，界面观察本地库；"正在输入"、通话状态这类临时事件经 events 流送出。
import Foundation
import QQBridgeProto

public enum ConnectionState: Sendable, Equatable {
  case connecting
  case online
  /// 断开了，多久之后重试。
  case offline(retryIn: TimeInterval, reason: String)
  /// 设备令牌失效（被吊销等），需要重新登录。
  case unauthenticated
}

public enum SyncEvent: Sendable {
  case connection(ConnectionState)
  case typing(Qqbridge_V1_TypingUpdate)
  case call(Qqbridge_V1_Call)
  /// 某个媒体下好了 / 拿不到了。
  case mediaReady(Qqbridge_V1_MediaReadyUpdate)
}

public actor SyncEngine {
  public struct Options: Sendable {
    public var differenceLimit: UInt32 = 500
    public var chatPageSize: UInt32 = 50
    /// 启动和重连后预取多少个会话的首屏。
    public var prefetchChats: Int = 30
    public var gapWait: Duration = .milliseconds(500)
    public var maxBackoff: TimeInterval = 30
    public init() {}
  }

  private let api: any SyncAPI
  private let store: LocalStore
  private let options: Options
  private var runTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]
  public private(set) var connection: ConnectionState = .connecting
  private var fetchingMessages: [String: Task<Qqbridge_V1_Message?, Never>] = [:]
  private var loadingChats: [Int64: Int] = [:]
  private var observedChatPts: [Int64: Int64] = [:]

  public init(api: any SyncAPI, store: LocalStore, options: Options = Options()) {
    self.api = api
    self.store = store
    self.options = options
  }

  /// 临时事件与连接状态。每次调用得到一个独立的流。
  public func events() -> AsyncStream<SyncEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
    continuations[id] = continuation
    continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
    continuation.yield(.connection(connection))
    return stream
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }

  private func emit(_ event: SyncEvent) {
    if case .connection(let state) = event { connection = state }
    for c in continuations.values { c.yield(event) }
  }

  // MARK: 生命周期

  /// 开始同步（回到前台时调用；重复调用无副作用）。
  public func start() {
    guard runTask == nil else { return }
    runTask = Task { await self.runLoop() }
  }

  /// 停止同步（进入后台时调用）。
  public func stop() {
    runTask?.cancel()
    runTask = nil
  }

  private func runLoop() async {
    var backoff: TimeInterval = 1
    while !Task.isCancelled {
      do {
        emit(.connection(.connecting))
        let state = try await api.getState()
        try Task.checkCancellation()
        try store.setQqAccounts(state.qqAccounts)
        try await catchUp()
        await prefetch()
        try Task.checkCancellation()
        emit(.connection(.online))
        backoff = 1
        try await consume(api.subscribe(pts: try store.pts()))
        // 服务端正常结束了流（例如重启）：立即重连。
      } catch is CancellationError {
        return
      } catch let error as APIError where error.isUnauthenticated {
        // 停止后迟到的鉴权错误属于旧连接，不能让已恢复的新连接退出登录。
        guard !Task.isCancelled else { return }
        emit(.connection(.unauthenticated))
        return
      } catch {
        if Task.isCancelled { return }
        emit(.connection(.offline(retryIn: backoff, reason: "\(error)")))
        try? await Task.sleep(for: .seconds(backoff))
        backoff = min(backoff * 2, options.maxBackoff)
      }
    }
  }

  // MARK: 全局差量

  /// 用 GetDifference 把会话列表、资料、发件箱追到最新。
  public func catchUp() async throws {
    var pts = try store.pts()
    while true {
      try Task.checkCancellation()
      let d = try await api.getDifference(pts: pts, limit: options.differenceLimit)
      // 2026-10-14 延迟响应检查：传输层可能在取消后仍返回；写库或 tooLong 清库前必须再检查。
      try Task.checkCancellation()
      guard try store.pts() == pts else {
        pts = try store.pts()
        continue
      }
      if d.tooLong {
        // 游标太旧：清空本地缓存，从 0 全量重拉。
        try store.reset()
        pts = 0
        continue
      }
      try store.apply(difference: d)
      try await repairLoadedChats(d.dialogs)
      pts = d.pts
      if d.isFinal { return }
    }
  }

  private func consume(_ stream: AsyncThrowingStream<Qqbridge_V1_SubscribeResponse, any Error>) async throws {
    for try await response in stream {
      try Task.checkCancellation()
      guard let event = response.event else { continue }
      switch event {
      case .difference(let d):
        if d.tooLong {
          try store.reset()
          throw ResyncNeeded()
        }
        try store.apply(difference: d)
        try await repairLoadedChats(d.dialogs)
      case .dialog(let u):
        try await withPts(u.pts) { try self.store.apply(dialog: u.dialog, pts: u.pts) }
      case .peer(let u):
        try await withPts(u.pts) { try self.store.apply(peer: u.peer, pts: u.pts) }
      case .tombstone(let u):
        try await withPts(u.pts) { try self.store.apply(tombstone: u.tombstone, pts: u.pts) }
      case .outbox(let u):
        try await withPts(u.pts) { try self.store.apply(outbox: u.entry, pts: u.pts) }
      case .chatMessage(let u):
        try await withChatPts(u.chatID, u.chatPts) { contiguousTop in
          try self.store.applyChat(
            chatId: u.chatID,
            messages: [u.message],
            events: [],
            newChatPts: u.chatPts,
            contiguous: contiguousTop.map { SeqRange($0, max($0, u.message.seq)) }
          )
        }
      case .chatEvent(let u):
        try await withChatPts(u.chatID, u.chatPts) { _ in
          try self.store.applyChat(chatId: u.chatID, messages: [], events: [u.event], newChatPts: u.chatPts)
        }
      case .heartbeat(let h):
        if h.pts > (try store.pts()) { try await catchUp() }
      case .resync:
        throw ResyncNeeded()
      case .typing(let t):
        emit(.typing(t))
      case .call(let c):
        emit(.call(c.call))
      case .mediaReady(let m):
        emit(.mediaReady(m))
      }
    }
  }

  private struct ResyncNeeded: Error {}

  /// 差量回放只有会话摘要；已缓存会话必须补消息，不能依赖最近 30 个会话的预取。
  private func repairLoadedChats(_ dialogs: [Qqbridge_V1_Dialog]) async throws {
    for dialog in dialogs {
      try Task.checkCancellation()
      let local = try store.chatState(chatId: dialog.chatID).chatPts
      if local > 0, local < dialog.chatPts { try await catchUpChat(dialog.chatID) }
    }
  }

  private func beginLoading(_ chatId: Int64) {
    loadingChats[chatId, default: 0] += 1
  }

  private func endLoading(_ chatId: Int64) {
    if let count = loadingChats[chatId], count > 1 { loadingChats[chatId] = count - 1 }
    else { loadingChats[chatId] = nil; observedChatPts[chatId] = nil }
  }

  /// 按全局 pts 规则应用一条更新。
  private func withPts(_ pts: Int64, apply: () throws -> Void) async throws {
    let local = try store.pts()
    if pts <= local { return }
    if pts == local + 1 {
      try apply()
      return
    }
    // 中间缺了：稍等一下（乱序到达的可能马上就来），再用差量补齐（差量里包含这一条）。
    try await Task.sleep(for: options.gapWait)
    if pts > (try store.pts()) { try await catchUp() }
  }

  /// 按会话 chat_pts 规则应用一条更新。apply 收到"最新已加载区间的下界"（新消息顺延这个区间）。
  private func withChatPts(_ chatId: Int64, _ chatPts: Int64, apply: (Int64?) throws -> Void) async throws {
    // 首屏请求期间到达的消息尚不能直接写入连续区间，但必须记住追平目标，避免旧首屏漏消息。
    if loadingChats[chatId] != nil { observedChatPts[chatId] = max(observedChatPts[chatId] ?? 0, chatPts) }
    let state = try store.chatState(chatId: chatId)
    if state.chatPts == 0 { return }  // 没加载过的会话不跟踪消息
    if chatPts <= state.chatPts { return }
    if chatPts == state.chatPts + 1 {
      try apply(state.newestLoadedLowerBound)
      return
    }
    try await Task.sleep(for: options.gapWait)
    if chatPts > (try store.chatState(chatId: chatId)).chatPts { try await catchUpChat(chatId) }
  }

  // MARK: 会话

  /// 打开会话：没加载过就拉首屏，加载过就把离线期间的变化补上。
  public func openChat(_ chatId: Int64) async throws {
    try store.markOpened(chatId: chatId)
    try await catchUpChat(chatId)
  }

  /// 把一个会话的变化追到最新；是否还有下一页以响应为准，不能因本地尚未缓存就提前结束。
  public func catchUpChat(_ chatId: Int64) async throws {
    beginLoading(chatId)
    defer { endLoading(chatId) }
    while true {
      try Task.checkCancellation()
      let local = try store.chatState(chatId: chatId)
      let res = try await api.getChatDifference(chatId: chatId, chatPts: local.chatPts, limit: options.chatPageSize)
      try Task.checkCancellation()
      // actor 在网络等待期间可重入：预取、另一个窗口或实时推送可能已经推进了游标。
      // 旧响应尤其不能用 tooLong 清掉新窗口；按当前游标重取，确保调用方等到真正追平。
      guard try store.chatState(chatId: chatId).chatPts == local.chatPts else { continue }
      let firstScreen = local.chatPts == 0 || res.tooLong
      try store.applyChat(
        chatId: chatId,
        messages: res.messages,
        events: res.events,
        newChatPts: res.chatPts,
        reset: res.tooLong,
        contiguous: firstScreen ? Self.span(res.messages) : nil
      )
      if res.isFinal, res.chatPts >= (observedChatPts[chatId] ?? 0) { return }
    }
  }

  /// 往上翻页：从已加载的最早一条往前要一页（服务端没有的会现场向 QQ 拉）。返回拿到的条数，0 表示到头了。
  @discardableResult
  public func loadOlder(_ chatId: Int64, limit: UInt32? = nil) async throws -> Int {
    let state = try store.chatState(chatId: chatId)
    let before = state.newestLoadedLowerBound
    let res = try await api.getHistory(chatId: chatId, beforeSeq: before, limit: limit ?? options.chatPageSize)
    try Task.checkCancellation()
    let lowest = res.messages.map(\.seq).min()
    // 这一页与已加载区间连在一起：[这一页最早的, 原来的下界 - 1]。
    let range = lowest.map { SeqRange($0, (before ?? (res.messages.map(\.seq).max() ?? $0) + 1) - 1) }
    try store.applyChat(
      chatId: chatId,
      messages: res.messages,
      events: res.events,
      newChatPts: state.chatPts == 0 ? res.chatPts : nil,
      contiguous: range
    )
    return res.messages.count
  }

  /// 取单条消息（例如回复引用的那条本地还没有）：放进本地库，但不并入已加载区间。同一条同时只取一次。
  @discardableResult
  public func fetchMessage(chatId: Int64, seq: Int64) async -> Qqbridge_V1_Message? {
    let key = "\(chatId):\(seq)"
    if let running = fetchingMessages[key] { return await running.value }
    let task = Task<Qqbridge_V1_Message?, Never> {
      guard let res = try? await api.getHistory(chatId: chatId, beforeSeq: seq + 1, limit: 1),
        let m = res.messages.first(where: { $0.seq == seq })
      else { return nil }
      try? store.applyChat(chatId: chatId, messages: [m], events: [], newChatPts: nil)
      return m
    }
    fetchingMessages[key] = task
    defer { fetchingMessages[key] = nil }
    return await task.value
  }

  /// 预取最近会话的首屏（以及已加载会话的变化），切换会话时直接读本地。
  public func prefetch() async {
    guard let dialogs = try? store.dialogs(limit: options.prefetchChats), !dialogs.isEmpty else { return }
    var wanted: [(chatId: Int64, chatPts: Int64)] = []
    for d in dialogs {
      let local = (try? store.chatState(chatId: d.chatID).chatPts) ?? 0
      if local == 0 || local < d.chatPts { wanted.append((d.chatID, local)) }
    }
    guard !wanted.isEmpty else { return }
    for item in wanted { beginLoading(item.chatId) }
    defer { for item in wanted { endLoading(item.chatId) } }
    guard let results = try? await api.getChatDifferences(wanted, perChatLimit: 30) else { return }
    guard !Task.isCancelled else { return }
    let localPts = Dictionary(uniqueKeysWithValues: wanted.map { ($0.chatId, $0.chatPts) })
    for r in results {
      guard !Task.isCancelled else { return }
      guard let requestedPts = localPts[r.chatID], let current = try? store.chatState(chatId: r.chatID) else { continue }
      if current.chatPts != requestedPts {
        // 打开会话与批量预取交错时不应用旧快照；仍落后的会话从新的游标补齐。
        if current.chatPts < max(r.chatPts, observedChatPts[r.chatID] ?? 0) { try? await catchUpChat(r.chatID) }
        continue
      }
      let firstScreen = requestedPts == 0 || r.tooLong
      try? store.applyChat(
        chatId: r.chatID,
        messages: r.messages,
        events: r.events,
        newChatPts: r.chatPts,
        reset: r.tooLong && requestedPts > 0,
        contiguous: firstScreen ? Self.span(r.messages) : nil
      )
      if !r.isFinal || r.chatPts < (observedChatPts[r.chatID] ?? 0) { try? await catchUpChat(r.chatID) }
    }
  }

  /// 首屏这一页覆盖的 seq 区间（服务端给的首屏是最新的连续一段）。
  static func span(_ messages: [Qqbridge_V1_Message]) -> SeqRange? {
    guard let lo = messages.map(\.seq).min(), let hi = messages.map(\.seq).max() else { return nil }
    return SeqRange(lo, hi)
  }
}
