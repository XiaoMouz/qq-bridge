import AVFoundation
import Observation

/// 群相册只保留当前页的播放器；视图重算不能重置播放，邻页也不能继续发声或预加载视频。
@MainActor
@Observable
final class URLGalleryPlayback {
  private(set) var player: AVPlayer?
  private var selection: Int?
  private var source: URL?

  func select(index: Int, url: URL?) {
    guard selection != index || source != url else { return }
    close()
    selection = index
    source = url
    if let url { player = AVPlayer(url: url) }
  }

  func close() {
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    selection = nil
    source = nil
  }
}
