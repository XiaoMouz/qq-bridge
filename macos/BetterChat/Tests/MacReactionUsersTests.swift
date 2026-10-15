import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class ReactionUserReplies: MacReactionUsersService {
  var calls: [(String, CheckedContinuation<[Qqbridge_V1_ReactionUser], any Error>)] = []
  func load(emojiID: String) async throws -> [Qqbridge_V1_ReactionUser] {
    try await withCheckedThrowingContinuation { calls.append((emojiID, $0)) }
  }
  func ready(_ count: Int) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while calls.count < count, ContinuousClock.now < deadline { await Task.yield() }
    #expect(calls.count == count)
  }
  func users(_ id: Int64) -> [Qqbridge_V1_ReactionUser] {
    var user = Qqbridge_V1_ReactionUser()
    user.userID = id
    user.name = "测试成员"
    return [user]
  }
}

@Suite(.serialized) @MainActor
struct MacReactionUsersTests {
  @Test func failureRequiresExplicitRetryAndEmptyIsSuccessful() async {
    let replies = ReactionUserReplies()
    let model = MacReactionUsersViewModel(selected: "1", service: replies)
    let failed = model.load()
    model.start()
    await replies.ready(1)
    replies.calls[0].1.resume(throwing: URLError(.notConnectedToInternet))
    await failed.value
    #expect(!model.isLoading && !model.hasLoaded && model.error != nil)
    model.start()
    #expect(replies.calls.count == 1)
    let retry = model.load()
    await replies.ready(2)
    replies.calls[1].1.resume(returning: [])
    await retry.value
    #expect(model.hasLoaded && model.users.isEmpty && model.error == nil && !model.isLoading)
  }

  @Test func switchingEmojiRejectsLateSuccessAndFailure() async {
    let replies = ReactionUserReplies()
    let model = MacReactionUsersViewModel(selected: "1", service: replies)
    let first = model.load()
    await replies.ready(1)
    model.select("2")
    let second = model.load()
    await replies.ready(2)
    replies.calls[0].1.resume(returning: replies.users(111))
    await first.value
    #expect(model.selected == "2" && model.isLoading && model.users.isEmpty && !model.hasLoaded)
    model.select("3")
    let third = model.load()
    await replies.ready(3)
    replies.calls[2].1.resume(returning: replies.users(333))
    await third.value
    replies.calls[1].1.resume(throwing: URLError(.timedOut))
    await second.value
    #expect(model.selected == "3" && model.users.map(\.userID) == [333] && model.error == nil)
    #expect(replies.calls.map(\.0) == ["1", "2", "3"])
  }

  @Test func refreshFailureKeepsUsersAndSwitchBackUsesCache() async {
    let replies = ReactionUserReplies()
    let model = MacReactionUsersViewModel(selected: "1", service: replies)
    let first = model.load()
    await replies.ready(1)
    replies.calls[0].1.resume(returning: replies.users(111))
    await first.value
    let refresh = model.load()
    await replies.ready(2)
    #expect(model.users.map(\.userID) == [111] && model.isLoading)
    replies.calls[1].1.resume(throwing: URLError(.timedOut))
    await refresh.value
    #expect(model.users.map(\.userID) == [111] && model.hasLoaded && model.error != nil)
    model.select("2")
    let second = model.load()
    await replies.ready(3)
    replies.calls[2].1.resume(returning: [])
    await second.value
    model.select("1")
    #expect(model.users.map(\.userID) == [111] && !model.isLoading && model.error == nil)
    #expect(replies.calls.count == 3)
  }

  @Test func closingAndReopeningRejectsOldReplyAndReleaseDoesNotLeak() async {
    let replies = ReactionUserReplies()
    var model: MacReactionUsersViewModel? = MacReactionUsersViewModel(selected: "1", service: replies)
    weak var released = model
    let old = model!.load()
    await replies.ready(1)
    model!.cancel()
    #expect(!model!.isLoading)
    let current = model!.load()
    await replies.ready(2)
    replies.calls[0].1.resume(returning: replies.users(111))
    await old.value
    #expect(model!.users.isEmpty && model!.isLoading)
    model = nil
    #expect(released == nil)
    replies.calls[1].1.resume(returning: replies.users(222))
    await current.value
  }
}
