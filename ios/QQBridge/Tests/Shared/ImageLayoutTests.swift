import Testing
import UIKit
@testable import BetterChat

@Suite(.serialized)
@MainActor
struct ImageLayoutTests {
  private func viewer(imageSize: CGSize, viewport: CGSize) -> CenteringScrollView {
    let scroll = CenteringScrollView(frame: CGRect(origin: .zero, size: viewport))
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.addSubview(scroll.imageView)
    scroll.imageView.image = UIGraphicsImageRenderer(size: imageSize).image { context in
      UIColor.orange.setFill()
      context.fill(CGRect(origin: .zero, size: imageSize))
    }
    scroll.setNeedsLayout()
    scroll.layoutIfNeeded()
    return scroll
  }

  /// 普通竖照不能因桌面窗口变矮而从完整预览变成裁切的长图。
  #if targetEnvironment(macCatalyst)
  @Test func portraitRemainsFullyVisibleAcrossWindowSizes() {
    let scroll = viewer(imageSize: CGSize(width: 360, height: 640), viewport: CGSize(width: 440, height: 428))
    for size in [CGSize(width: 440, height: 428), CGSize(width: 1024, height: 588), CGSize(width: 440, height: 588)] {
      scroll.frame.size = size
      scroll.setNeedsLayout()
      scroll.layoutIfNeeded()
      let image = scroll.imageView.frame.size
      #expect(image.width <= size.width + 0.5)
      #expect(image.height <= size.height + 0.5)
      #expect(abs(image.width / image.height - 360.0 / 640.0) < 0.001)
      #expect(scroll.minimumZoomScale == 1)
    }
  }
  #else
  /// 手机沿用按宽度阅读长于视口的图片，缩小后应能看到全图。
  @Test func portraitKeepsPhoneReadingLayoutAndCanZoomOut() {
    let scroll = viewer(imageSize: CGSize(width: 360, height: 640), viewport: CGSize(width: 402, height: 430))
    let coordinator = ZoomableImage.Coordinator(onTap: {})
    scroll.delegate = coordinator
    defer { withExtendedLifetime(coordinator) {} }
    #expect(abs(scroll.imageView.frame.width - 402) < 0.5)
    #expect(scroll.contentSize.height > 430)
    #expect(scroll.minimumZoomScale < 1)
    scroll.zoomScale = scroll.minimumZoomScale
    scroll.layoutIfNeeded()
    #expect(scroll.imageView.frame.height <= 430.5)
  }
  #endif

  @Test func landscapeRemainsFullyVisibleInNarrowWindow() {
    let scroll = viewer(imageSize: CGSize(width: 640, height: 360), viewport: CGSize(width: 440, height: 428))
    #expect(scroll.imageView.frame.width <= 440.5)
    #expect(scroll.imageView.frame.height <= 428.5)
    #expect(abs(scroll.imageView.frame.width / scroll.imageView.frame.height - 640.0 / 360.0) < 0.001)
  }

  /// 真正的长截图继续按宽度阅读，允许滚动及缩小查看全貌。
  @Test func longScreenshotRetainsScrollableReadingLayout() {
    let scroll = viewer(imageSize: CGSize(width: 360, height: 1800), viewport: CGSize(width: 440, height: 428))
    #expect(abs(scroll.imageView.frame.width - 440) < 0.5)
    #expect(scroll.contentSize.height > scroll.bounds.height)
    #expect(scroll.minimumZoomScale < 1)
    #expect(scroll.atTop)
    scroll.contentOffset.y = 200
    #expect(!scroll.atTop)
  }
}
