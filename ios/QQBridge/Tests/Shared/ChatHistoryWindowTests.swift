import Foundation
import QQBridgeKit
import Testing
@testable import BetterChat

/// 假的历史窗口服务：本地区间按脚本给，网络请求记次数。
@MainActor
private final class WindowReplies: ChatHistoryWindowService {
  var ranges: [SeqRange] = []
  var aroundAdds: SeqRange?
  var olderCount = 0
  var fail = false
  private(set) var calls: [String] = []

  func localRange(containing seq: Int64) throws -> (range: SeqRange, isNewest: Bool)? {
    guard let i = ranges.firstIndex(where: { $0.lo <= seq && seq <= $0.hi }) else { return nil }
    return (ranges[i], i == ranges.count - 1)
  }
  func loadAround(_ seq: Int64) async throws {
    calls.append("around:\(seq)")
    if fail { throw URLError(.timedOut) }
    if let aroundAdds { ranges.insert(aroundAdds, at: 0) }
  }
  func loadOlder(before seq: Int64) async throws -> Int {
    calls.append("older:\(seq)")
    return olderCount
  }
  func loadNewer(after seq: Int64) async throws -> Int {
    calls.append("newer:\(seq)")
    return 0
  }
}

@Suite(.serialized) @MainActor
struct ChatHistoryWindowTests {
  @Test func farTargetLoadsAroundAndOpensWindow() async {
    let service = WindowReplies(), window = ChatHistoryWindow()
    service.ranges = [SeqRange(900_000, 900_050)]
    service.aroundAdds = SeqRange(526_900, 527_000)
    #expect(await window.open(at: 526_948, using: service) == .opened)
    #expect(window.isActive && window.anchor == 526_948 && window.pendingTarget == 526_948)
    #expect(window.range == SeqRange(526_900, 527_000) && service.calls == ["around:526948"])
  }

  @Test func localHistorySegmentOpensWithoutNetwork() async {
    let service = WindowReplies(), window = ChatHistoryWindow()
    service.ranges = [SeqRange(-5, 40), SeqRange(1000, 1100)]
    #expect(await window.open(at: -3, using: service) == .opened)
    #expect(service.calls.isEmpty && window.contains(-3))
  }

  @Test func targetInNewestStaysInLatestList() async {
    let service = WindowReplies(), window = ChatHistoryWindow()
    service.ranges = [SeqRange(1000, 1100)]
    service.aroundAdds = SeqRange(990, 999)  // 取回来的一页并不包含目标所在的最新那段以外的区间
    #expect(await window.open(at: 1050, using: service) == .inNewest)
    #expect(!window.isActive)
  }

  @Test func missingTargetAndNetworkErrorsFail() async {
    let service = WindowReplies(), window = ChatHistoryWindow()
    service.ranges = [SeqRange(1000, 1100)]
    #expect(await window.open(at: 5, using: service) == .failed("这条消息已不存在或暂时不可用"))
    service.fail = true
    if case .failed(let message) = await window.open(at: 6, using: service) { #expect(!message.isEmpty) } else { Issue.record("应当失败") }
    #expect(!window.isActive && !window.opening)
  }

  @Test func pagingUsesWindowEdgesAndStopsAtStart() async {
    let service = WindowReplies(), window = ChatHistoryWindow()
    service.ranges = [SeqRange(100, 200), SeqRange(1000, 1100)]
    _ = await window.open(at: 150, using: service)
    service.olderCount = 0
    await window.loadOlder(using: service)
    await window.loadOlder(using: service)  // 到头后不再请求
    await window.loadNewer(using: service)
    #expect(service.calls == ["older:100", "newer:200"] && window.reachedStart)
    window.close()
    await window.loadOlder(using: service)
    #expect(service.calls.count == 2 && !window.isActive && window.range == nil)
  }
}
