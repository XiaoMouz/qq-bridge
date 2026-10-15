import Foundation
import QQBridgeProto
import Testing
@testable import BetterChat

@MainActor private final class GroupResourceReplies {
  var requests: [CheckedContinuation<[Int64], any Error>] = []
  func fetch() async throws -> [Int64] {
    try await withCheckedThrowingContinuation { requests.append($0) }
  }
  func ready(_ count: Int) async {
    let limit = ContinuousClock.now + .seconds(3)
    while requests.count < count, ContinuousClock.now < limit { await Task.yield() }
    #expect(requests.count == count)
  }
  func members() async throws -> [Qqbridge_V1_GroupMember] {
    try await fetch().map { id in var member = Qqbridge_V1_GroupMember(); member.userID = id; return member }
  }
}

@Suite(.serialized) @MainActor
struct MacGroupResourceTests {
  @Test func firstFailureAndSuccessfulEmptyAreDifferentStates() async {
    let replies = GroupResourceReplies()
    let model = MacGroupResource<[Int64]>()
    let first = model.load(groupID: 1) { try await replies.fetch() }
    await replies.ready(1)
    #expect(model.isLoading && !model.hasLoaded)
    replies.requests[0].resume(throwing: URLError(.notConnectedToInternet))
    await first.value
    #expect(model.error != nil && !model.hasLoaded && !model.isLoading)
    let retry = model.load(groupID: 1) { try await replies.fetch() }
    await replies.ready(2)
    replies.requests[1].resume(returning: [])
    await retry.value
    #expect(model.value == [] && model.hasLoaded && model.error == nil)
  }

  @Test func failedRefreshKeepsSnapshotAndDuplicateRefreshSharesRequest() async {
    let replies = GroupResourceReplies()
    let model = MacGroupResource<[Int64]>()
    let first = model.load(groupID: 1) { try await replies.fetch() }
    await replies.ready(1)
    replies.requests[0].resume(returning: [42])
    await first.value
    let refresh = model.load(groupID: 1) { try await replies.fetch() }
    let duplicate = model.load(groupID: 1) { Issue.record("重复刷新不应另发请求"); return [] }
    await replies.ready(2)
    #expect(model.value == [42] && model.isLoading)
    replies.requests[1].resume(throwing: URLError(.timedOut))
    await refresh.value
    await duplicate.value
    #expect(model.value == [42] && model.hasLoaded && model.error != nil && !model.isLoading)
  }

  @Test func cancelledSuccessCannotOverwriteNewGroup() async { await verifyLateReply(fails: false) }
  @Test func cancelledFailureCannotOverwriteNewGroup() async { await verifyLateReply(fails: true) }

  private func verifyLateReply(fails: Bool) async {
    let replies = GroupResourceReplies()
    let model = MacGroupResource<[Int64]>()
    let old = model.load(groupID: 1) { try await replies.fetch() }
    await replies.ready(1)
    let current = model.load(groupID: 2) { try await replies.fetch() }
    await replies.ready(2)
    #expect(model.value == nil && model.groupID == 2)
    replies.requests[1].resume(returning: [20])
    await current.value
    if fails { replies.requests[0].resume(throwing: URLError(.timedOut)) }
    else { replies.requests[0].resume(returning: [10]) }
    await old.value
    #expect(model.value == [20] && model.error == nil && !model.isLoading)
  }

  @Test func cancellingAndReturningCanStartAgain() async {
    let replies = GroupResourceReplies()
    let model = MacGroupResource<[Int64]>()
    let old = model.load(groupID: 1) { try await replies.fetch() }
    await replies.ready(1)
    model.cancel()
    #expect(!model.isLoading && model.error == nil && !model.hasLoaded)
    let current = model.load(groupID: 1) { try await replies.fetch() }
    await replies.ready(2)
    replies.requests[0].resume(returning: [10])
    await old.value
    #expect(model.isLoading && model.value == nil)
    replies.requests[1].resume(returning: [20])
    await current.value
    #expect(model.value == [20])
  }

  @Test func memberFailureCanRetryWithoutForceAndBuildsLookup() async {
    let replies = GroupResourceReplies()
    let members = GroupMembers()
    let first = members.load(groupId: 1) { try await replies.members() }
    await replies.ready(1)
    replies.requests[0].resume(throwing: URLError(.notConnectedToInternet))
    await first.value
    #expect(!members.hasLoaded && members.error != nil && members.list.isEmpty)
    let retry = members.load(groupId: 1) { try await replies.members() }
    await replies.ready(2)
    replies.requests[1].resume(returning: [10, 20])
    await retry.value
    #expect(members.hasLoaded && members.error == nil && members.list.count == 2)
    #expect(members.byId[20]?.userID == 20)
    await members.load(groupId: 1) { Issue.record("缓存成功后不应重复请求"); return [] }.value
  }

  @Test func memberRefreshFailureKeepsNamesUntilSuccessfulEmpty() async {
    let replies = GroupResourceReplies()
    let members = GroupMembers()
    let first = members.load(groupId: 1) { try await replies.members() }
    await replies.ready(1)
    replies.requests[0].resume(returning: [10, 20])
    await first.value
    let refresh = members.load(groupId: 1, refresh: true) { try await replies.members() }
    await replies.ready(2)
    replies.requests[1].resume(throwing: URLError(.timedOut))
    await refresh.value
    #expect(members.byId.count == 2 && members.list.count == 2 && members.error != nil)
    let retry = members.load(groupId: 1, refresh: true) { try await replies.members() }
    await replies.ready(3)
    replies.requests[2].resume(returning: [])
    await retry.value
    #expect(members.list.isEmpty && members.byId.isEmpty && members.hasLoaded && members.error == nil)
  }
  @Test func forcedMemberRefreshSupersedesOrdinaryCacheRead() async {
    let replies = GroupResourceReplies()
    let members = GroupMembers()
    let ordinary = members.load(groupId: 1) { try await replies.members() }
    await replies.ready(1)
    let forced = members.load(groupId: 1, refresh: true) { try await replies.members() }
    await replies.ready(2)
    let duplicate = members.load(groupId: 1, refresh: true) { Issue.record("不重复强制刷新"); return [] }
    replies.requests[1].resume(returning: [20])
    await forced.value
    await duplicate.value
    replies.requests[0].resume(returning: [10])
    await ordinary.value
    #expect(members.list.map(\.userID) == [20] && members.error == nil)
  }

  @Test func returningRestartsInterruptedProfileRefreshWithoutDroppingOldValue() async {
    let replies = GroupResourceReplies()
    let model = MacGroupProfileViewModel(groupID: 1) {
      let values = try await replies.fetch()
      var profile = Qqbridge_V1_GroupProfile()
      profile.peer.memberCount = UInt32(values.count)
      return profile
    }
    let first = model.load()
    await replies.ready(1)
    replies.requests[0].resume(returning: [10])
    await first.value
    let interrupted = model.load()
    await replies.ready(2)
    model.cancel()
    #expect(model.profile?.peer.memberCount == 1 && !model.isLoading)
    model.start()
    let resumed = model.load()
    await replies.ready(3)
    replies.requests[2].resume(returning: [10, 20])
    await resumed.value
    replies.requests[1].resume(throwing: URLError(.timedOut))
    await interrupted.value
    #expect(model.profile?.peer.memberCount == 2 && model.error == nil)
    model.cancel()
    model.start()
    #expect(!model.isLoading && replies.requests.count == 3)
  }

}
