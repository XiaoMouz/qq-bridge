import AVFoundation
import Testing
@testable import BetterChat

@MainActor @Suite(.serialized)
struct URLGalleryPlaybackTests {
  private let first = URL(fileURLWithPath: "/tmp/betterchat-gallery-first-missing.mp4")
  private let second = URL(fileURLWithPath: "/tmp/betterchat-gallery-second-missing.mp4")

  @Test func repeatedSelectionPreservesPlayerAndItem() throws {
    let model = URLGalleryPlayback()
    defer { model.close() }
    model.select(index: 1, url: first)
    let player = try #require(model.player)
    let item = try #require(player.currentItem)
    model.select(index: 1, url: first)
    #expect(model.player === player && player.currentItem === item)
    #expect(player.rate == 0)
  }

  @Test func imageSelectionReleasesVideoItem() throws {
    let model = URLGalleryPlayback()
    defer { model.close() }
    model.select(index: 1, url: first)
    let old = try #require(model.player)
    model.select(index: 2, url: nil)
    #expect(model.player == nil && old.currentItem == nil && old.rate == 0)
  }

  @Test func nextVideoReplacesAndReleasesPreviousPlayer() throws {
    let model = URLGalleryPlayback()
    defer { model.close() }
    model.select(index: 0, url: first)
    let old = try #require(model.player)
    model.select(index: 1, url: second)
    #expect(model.player != nil && model.player !== old)
    #expect(old.currentItem == nil && old.rate == 0)
  }

  @Test func changedSourceOnSamePageReplacesPlayer() throws {
    let model = URLGalleryPlayback()
    defer { model.close() }
    model.select(index: 0, url: first)
    let old = try #require(model.player)
    model.select(index: 0, url: second)
    #expect(model.player != nil && model.player !== old && old.currentItem == nil)
  }

  @Test func closeIsIdempotentAndSamePageCanReopen() throws {
    let model = URLGalleryPlayback()
    defer { model.close() }
    model.select(index: 0, url: first)
    let old = try #require(model.player)
    model.close()
    model.close()
    #expect(model.player == nil && old.currentItem == nil && old.rate == 0)
    model.select(index: 0, url: first)
    #expect(model.player != nil && model.player !== old)
  }
}
