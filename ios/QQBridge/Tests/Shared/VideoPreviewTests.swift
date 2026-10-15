import AVFoundation
import Testing
@testable import BetterChat

@MainActor
private final class VideoURLReply {
  private var reply: CheckedContinuation<URL?, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private var requested = false

  func resolve() async -> URL? {
    await withCheckedContinuation { continuation in
      reply = continuation
      requested = true
      started?.resume()
      started = nil
    }
  }

  func waitForRequest() async {
    if requested { return }
    await withCheckedContinuation { started = $0 }
  }

  func finish(_ url: URL?) {
    reply?.resume(returning: url)
    reply = nil
  }
}

@Suite(.serialized) @MainActor
struct VideoPreviewTests {
  // 只使用不存在的本机 URL；验证播放器所有权，不下载媒体或访问用户文件。
  private let url = URL(fileURLWithPath: "/tmp/betterchat-video-lifecycle-missing.mp4")

  @Test func closeBeforeURLReturnsNeverCreatesPlayer() async {
    let model = VideoPreviewModel()
    let reply = VideoURLReply()
    let task = Task { await model.load { await reply.resolve() } }
    await reply.waitForRequest()
    model.close()
    reply.finish(url)
    await task.value
    #expect(model.player == nil)
  }

  @Test func cancelledTaskIgnoresLateURL() async {
    let model = VideoPreviewModel()
    let reply = VideoURLReply()
    let task = Task { await model.load { await reply.resolve() } }
    await reply.waitForRequest()
    task.cancel()
    reply.finish(url)
    await task.value
    #expect(model.player == nil)
  }

  @Test func previousLoadCannotReplaceNewPlayer() async throws {
    let model = VideoPreviewModel()
    defer { model.close() }
    let reply = VideoURLReply()
    let old = Task { await model.load { await reply.resolve() } }
    await reply.waitForRequest()
    await model.load { url }
    let current = model.player
    reply.finish(url)
    await old.value
    #expect(current != nil && model.player === current)
  }

  @Test func closePausesPlayerBeforeItsControllerIsMounted() async throws {
    let model = VideoPreviewModel()
    await model.load { url }
    let player = try #require(model.player)
    model.close()
    #expect(player.rate == 0 && model.player == nil)
    model.close()
    #expect(player.rate == 0)
  }

  @Test func failedResolutionLeavesNoPlayerAndCanRetry() async {
    let model = VideoPreviewModel()
    defer { model.close() }
    await model.load { nil }
    #expect(model.player == nil)
    await model.load { url }
    #expect(model.player != nil)
  }
}
