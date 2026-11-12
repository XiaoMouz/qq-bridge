import Testing
@testable import BetterChat

/// iPhone 被系统回收后恢复正在看的会话和位置（2026-11-12）：SceneStorage 里存的字符串与追踪规则。
@MainActor
struct ChatPositionTrackerTests {
  @Test func encodesAndParsesSavedPosition() {
    #expect(ChatPositionTracker.Saved("153:4200") == .init(chat: 153, seq: 4200))
    #expect(ChatPositionTracker.Saved("153") == .init(chat: 153, seq: nil))
    // 备份导入的消息 seq 是负数。
    #expect(ChatPositionTracker.Saved("153:-12") == .init(chat: 153, seq: -12))
    #expect(ChatPositionTracker.Saved("") == nil)
    #expect(ChatPositionTracker.Saved("abc") == nil)
    #expect(ChatPositionTracker.Saved(chat: 7, seq: -3).encoded == "7:-3")
    #expect(ChatPositionTracker.Saved(chat: 7, seq: nil).encoded == "7")
  }

  @Test func returningFromChildPageKeepsPositionAndLeavingClearsIt() {
    let tracker = ChatPositionTracker()
    tracker.enter(1)
    tracker.update(chat: 1, seq: 500)
    // 从群资料等下一级页面返回，会话页再次出现：位置不能被清掉。
    tracker.enter(1)
    #expect(tracker.encoded == "1:500")
    // 换到另一个会话：从最新开始。
    tracker.enter(2)
    #expect(tracker.encoded == "2")
    tracker.update(chat: 2, seq: nil)
    #expect(tracker.encoded == "2")
    tracker.leave()
    #expect(tracker.encoded.isEmpty)
  }
}
