import AVKit
import Testing
@testable import BetterChat

/// 直接驱动系统代理的异常/迟到顺序；验证播放所有权，不把它当作系统小窗实机验收。
@MainActor @Suite(.serialized)
struct MacVideoPictureInPictureTests {
  @Test func failedStartAllowsClosedPreviewToReleaseController() {
    let playback = VideoPlayback()
    let player = AVPlayer()
    let controller = playback.controller(for: player)
    playback.playerViewControllerWillStartPictureInPicture(controller)
    let delegate: any AVPlayerViewControllerDelegate = playback
    delegate.playerViewController?(controller, failedToStartPictureInPictureWithError: NSError(domain: "BetterChat.Test", code: 1))
    playback.previewClosed(player)
    #expect(playback.controller(for: player) !== controller)
    playback.previewClosed(player)
  }

  @Test func previousStartCannotKeepNewPreviewAlive() {
    let playback = VideoPlayback()
    let old = playback.controller(for: AVPlayer())
    playback.playerViewControllerWillStartPictureInPicture(old)
    let player = AVPlayer()
    let current = playback.controller(for: player)
    playback.playerViewControllerWillStartPictureInPicture(old)
    playback.previewClosed(player)
    #expect(playback.controller(for: player) !== current)
    playback.previewClosed(player)
  }

  @Test func previousStopCannotClearCurrentPictureInPicture() {
    let playback = VideoPlayback()
    let old = playback.controller(for: AVPlayer())
    playback.playerViewControllerWillStartPictureInPicture(old)
    let player = AVPlayer()
    let current = playback.controller(for: player)
    playback.playerViewControllerWillStartPictureInPicture(current)
    playback.playerViewControllerDidStopPictureInPicture(old)
    playback.previewClosed(player)
    #expect(playback.controller(for: player) === current)
    playback.playerViewControllerDidStopPictureInPicture(current)
    playback.previewClosed(player)
  }

  @Test func oldInlineCallbackCannotKeepReplacementControllerAlive() {
    let playback = VideoPlayback()
    let player = AVPlayer()
    let inline = playback.controller(for: player)
    playback.playerViewControllerWillStartPictureInPicture(inline)
    let presented = playback.fullScreenController(for: player)
    playback.playerViewControllerWillStartPictureInPicture(inline)
    playback.previewClosed(player)
    #expect(playback.controller(for: player) !== presented)
    playback.previewClosed(player)
  }
}
