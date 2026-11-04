// 聊天页的「历史窗口」：跳到离最新很远的消息时，只显示目标前后那一段，上下翻页各自往外接，底部给「回到最新」。
// 2026-11-04：备份导入的老消息离最新可能有几十万条（好烫好烫里 2025-07 的一张图上面还有 34.7 万条），
// 原来的跳转从最新一段一页页往上接，要几百次请求、把几十万条都渲染出来。数据层见 SyncEngine.loadAround。
import Foundation
import Observation
import QQBridgeKit

@MainActor
protocol ChatHistoryWindowService {
  /// 本地包含 seq 的已加载区间，以及它是不是最新那段。
  func localRange(containing seq: Int64) throws -> (range: SeqRange, isNewest: Bool)?
  func loadAround(_ seq: Int64) async throws
  func loadOlder(before seq: Int64) async throws -> Int
  func loadNewer(after seq: Int64) async throws -> Int
}

@MainActor
struct SessionChatHistoryWindowService: ChatHistoryWindowService {
  let session: Session
  let chatId: Int64

  func localRange(containing seq: Int64) throws -> (range: SeqRange, isNewest: Bool)? {
    try session.store.loadedRange(chatId: chatId, containing: seq)
  }
  func loadAround(_ seq: Int64) async throws { try await session.sync.loadAround(chatId, seq: seq) }
  func loadOlder(before seq: Int64) async throws -> Int { try await session.sync.loadOlder(chatId, before: seq) }
  func loadNewer(after seq: Int64) async throws -> Int { try await session.sync.loadNewer(chatId, after: seq) }
}

@MainActor @Observable
final class ChatHistoryWindow {
  enum OpenResult: Equatable {
    /// 目标在一段和最新不相连的历史里：聊天页改为显示这一段。
    case opened
    /// 目标就在最新那段里（本来就在，或者取回来的一页正好接上了）：照常在最新那段里滚过去。
    case inNewest
    case failed(String)
  }

  /// 正在显示的历史窗口以哪条消息为锚（nil = 正常显示最新那段）。
  private(set) var anchor: Int64?
  /// 窗口这一段的 seq 区间（本地观察推过来的）。
  private(set) var range: SeqRange?
  private(set) var opening = false
  private(set) var loadingOlder = false
  private(set) var loadingNewer = false
  private(set) var reachedStart = false
  private(set) var error: String?
  /// 打开窗口后要滚过去、高亮的消息（列表里出现了就由聊天页清掉）。
  var pendingTarget: Int64?
  @ObservationIgnored private var generation = UUID()

  var isActive: Bool { anchor != nil }
  var isLoading: Bool { opening || loadingOlder || loadingNewer }

  func contains(_ seq: Int64) -> Bool {
    guard let range else { return false }
    return range.lo <= seq && seq <= range.hi
  }

  /// 本地已经有包含目标的历史段就直接用，否则先向服务端取目标前后一页。
  func open(at seq: Int64, using service: any ChatHistoryWindowService) async -> OpenResult {
    let request = UUID()
    generation = request
    opening = true
    error = nil
    defer { if generation == request { opening = false } }
    do {
      var local = try service.localRange(containing: seq)
      if local == nil {
        try await service.loadAround(seq)
        guard generation == request else { return .failed("") }
        local = try service.localRange(containing: seq)
      }
      guard let local else { return .failed("这条消息已不存在或暂时不可用") }
      if local.isNewest { return .inNewest }
      anchor = seq
      range = local.range
      reachedStart = false
      pendingTarget = seq
      return .opened
    } catch {
      guard generation == request else { return .failed("") }
      return .failed(LoadState.describe(error))
    }
  }

  /// 本地观察推来的这一段（区间被上下翻页接长时会变）。
  func update(range: SeqRange?) { self.range = range }

  func loadOlder(using service: any ChatHistoryWindowService) async {
    guard isActive, !loadingOlder, !reachedStart, let lo = range?.lo else { return }
    let request = generation
    loadingOlder = true
    error = nil
    defer { if generation == request { loadingOlder = false } }
    do {
      let count = try await service.loadOlder(before: lo)
      guard generation == request else { return }
      if count == 0 { reachedStart = true }
    } catch {
      guard generation == request else { return }
      self.error = LoadState.describe(error)
    }
  }

  func loadNewer(using service: any ChatHistoryWindowService) async {
    guard isActive, !loadingNewer, let hi = range?.hi else { return }
    let request = generation
    loadingNewer = true
    error = nil
    defer { if generation == request { loadingNewer = false } }
    do {
      _ = try await service.loadNewer(after: hi)
    } catch {
      guard generation == request else { return }
      self.error = LoadState.describe(error)
    }
  }

  /// 回到最新（点了按钮，或者往下翻到和最新那段接上了）。正在进行的请求结果照样写进本地库，只是不再改这里的状态。
  func close() {
    generation = UUID()
    anchor = nil
    range = nil
    opening = false
    loadingOlder = false
    loadingNewer = false
    reachedStart = false
    error = nil
    pendingTarget = nil
  }

  func dismissError() { error = nil }
}
