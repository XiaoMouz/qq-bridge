import AVFoundation
import Foundation
import Testing
@testable import BetterChat

@Suite(.serialized) @MainActor
struct MacMediaWindowTests {
  private let firstURL = URL(fileURLWithPath: "/tmp/betterchat-window-first-missing.mp4")
  private let secondURL = URL(fileURLWithPath: "/tmp/betterchat-window-second-missing.mp4")

  @Test func concurrentOpenRequestsKeepTheirOwnContentAndAreConsumedOnce() throws {
    var activities: [NSUserActivity] = []
    let windows = MacMediaWindows(activate: { activity, _ in activities.append(activity) }, reportFailure: {})
    windows.open(.gallery(URLGallery(items: [.video(firstURL)], index: 0)))
    windows.open(.gallery(URLGallery(items: [.image(secondURL)], index: 0)))
    #expect(activities.count == 2)
    #expect(activities[0].targetContentIdentifier != activities[1].targetContentIdentifier)
    guard case .gallery(let second) = windows.take([activities[1]]),
          case .gallery(let first) = windows.take([activities[0]]) else {
      Issue.record("每个场景必须得到自己的媒体"); return
    }
    #expect(second.items == [.image(secondURL)])
    #expect(first.items == [.video(firstURL)])
    #expect(windows.take([activities[0]]) == nil)
  }

  @Test func failedRequestDoesNotLoseAnotherPendingWindowAndCanRetry() {
    var activities: [NSUserActivity] = []
    var failures: [@MainActor () -> Void] = []
    var errorCount = 0
    let windows = MacMediaWindows(activate: { activity, failure in
      activities.append(activity); failures.append(failure)
    }, reportFailure: { errorCount += 1 })
    let content = MacMediaWindows.Content.gallery(URLGallery(items: [.video(firstURL)], index: 0))
    windows.open(content)
    windows.open(content)
    failures[0]()
    failures[0]()
    #expect(errorCount == 1)
    #expect(windows.take([activities[0]]) == nil)
    #expect(windows.take([activities[1]]) != nil)
    windows.open(content)
    #expect(windows.take([activities[2]]) != nil)
    failures[2]()
    #expect(errorCount == 1)
  }

  @Test func logoutInvalidatesWindowsThatHaveNotConnectedYet() {
    var activity: NSUserActivity?
    var failed: (@MainActor () -> Void)?
    var errors = 0
    let windows = MacMediaWindows(activate: { activity = $0; failed = $1 }, reportFailure: { errors += 1 })
    windows.open(.gallery(URLGallery(items: [.video(firstURL)], index: 0)))
    windows.cancelPending()
    #expect(windows.take(activity.map { [$0] } ?? []) == nil)
    failed?()
    #expect(errors == 0)
  }

  @Test func closingWindowReleasesOnlyItsOwnResourcesOnce() {
    let first = MacMediaWindowContext()
    let second = MacMediaWindowContext()
    var firstCount = 0
    var secondCount = 0
    first.registerCleanup("video") { firstCount += 1 }
    second.registerCleanup("video") { secondCount += 1 }
    first.releaseResources()
    first.releaseResources()
    #expect(firstCount == 1 && secondCount == 0)
    second.releaseResources()
    #expect(secondCount == 1)
  }

  @Test func separateVideoWindowsDoNotReplaceOrPauseEachOthersControllers() async throws {
    let first = VideoPreviewModel()
    let second = VideoPreviewModel()
    defer { first.close(); second.close() }
    await first.load { firstURL }
    await second.load { secondURL }
    let firstPlayer = try #require(first.player)
    let secondPlayer = try #require(second.player)
    let firstController = first.videoPlayback.controller(for: firstPlayer)
    let secondController = second.videoPlayback.controller(for: secondPlayer)
    #expect(first.videoPlayback !== second.videoPlayback)
    #expect(firstController !== secondController)
    #expect(first.videoPlayback.controller(for: firstPlayer) === firstController)
    first.close()
    #expect(second.player === secondPlayer)
    #expect(second.videoPlayback.controller(for: secondPlayer) === secondController)
  }
}
