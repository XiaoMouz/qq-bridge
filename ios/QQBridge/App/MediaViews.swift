// 媒体显示：头像、缩略图。图片经 MediaCache（按 sha256 缓存、有上限）加载，内存里再放一层小缓存，滚动时不反复解码。
import QQBridgeKit
import ImageIO
import SwiftUI
import UIKit

/// 解码后的图片放在内存里（按 sha256），列表来回滚动时直接用。
@MainActor
final class ImageMemoryCache {
  static let shared = ImageMemoryCache()
  private let cache = NSCache<NSString, UIImage>()
  init() { cache.totalCostLimit = 64 * 1024 * 1024 }
  func get(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }
  func set(_ key: String, _ image: UIImage) {
    let frames = max(image.images?.count ?? 1, 1)
    cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4) * frames)
  }
}

/// 按 sha256 显示一张图（缩略图、预览图、头像）。
struct CachedImage<Placeholder: View>: View {
  let sha256: String?
  var chatId: Int64? = nil
  /// 取不到时调用（例如原件已清理、QQ 上也过期了）。
  var onFailure: (() -> Void)? = nil
  /// 解码时缩到这个像素（长边）以内：列表里显示原图时不按原尺寸解码。nil = 原尺寸。
  var maxPixel: CGFloat? = nil
  /// 动图（GIF / APNG / 动态 WebP）按帧播放；单帧的照常显示。
  var animated = false
  /// 刚加载出来时（不是内存里现成的）从中间羽化地揭开，占位图在下面慢慢被盖住。
  var reveal = false
  @ViewBuilder var placeholder: () -> Placeholder
  @Environment(\.session) private var session
  @State private var image: UIImage?
  @State private var revealed: CGFloat = 1

  var body: some View {
    ZStack {
      if image == nil || revealed < 1 { placeholder() }
      if let image {
        Group {
          if image.images != nil { AnimatedImageView(image: image) } else { Image(uiImage: image).resizable() }
        }
        .mask {
          if reveal {
            GeometryReader { geo in
              let side = hypot(geo.size.width, geo.size.height)
              Circle()
                .frame(width: side, height: side)
                .scaleEffect(max(0.001, revealed * 1.3))
                .blur(radius: side * 0.12 * (1 - revealed * 0.8))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
          } else {
            Rectangle()
          }
        }
      }
    }
    .task(id: sha256) { await load() }
  }

  private func load() async {
    guard let sha256, !sha256.isEmpty, let session else {
      image = nil
      return
    }
    let key = (maxPixel.map { "\(sha256)@\(Int($0))" } ?? sha256) + (animated ? "#a" : "")
    if let hit = ImageMemoryCache.shared.get(key) {
      image = hit
      return
    }
    do {
      let file = try await session.media.file(for: sha256, chatId: chatId)
      let limit = maxPixel
      let animate = animated
      let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
        if animate, let moving = ImageDecoder.animated(file, maxPixel: limit ?? 1600) { return moving }
        if let limit { return ImageDecoder.downsampled(file, maxPixel: limit) }
        guard let img = UIImage(contentsOfFile: file.path) else { return nil }
        return await img.byPreparingForDisplay() ?? img
      }.value
      if let decoded {
        ImageMemoryCache.shared.set(key, decoded)
        if reveal {
          revealed = 0
          image = decoded
          withAnimation(.easeOut(duration: 0.7)) { revealed = 1 }
        } else {
          image = decoded
        }
      }
    } catch {
      image = nil
      if !(error is CancellationError) { onFailure?() }
    }
  }
}

/// 圆形头像：有头像显示头像，没有就用名字首字和按号码算出的颜色。
struct AvatarView: View {
  let sha256: String?
  let title: String
  let seed: Int64
  var size: CGFloat = 48

  var body: some View {
    CachedImage(sha256: sha256) {
      ZStack {
        Circle().fill(Self.color(seed).gradient)
        Text(String(title.prefix(1)))
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(.white)
      }
    }
    .aspectRatio(contentMode: .fill)
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  static func color(_ seed: Int64) -> Color {
    let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan]
    return palette[Int(UInt64(bitPattern: seed) % UInt64(palette.count))]
  }
}

/// 按显示需要缩小解码（ImageIO 直接出小图，不先解出整张大图）。
enum ImageDecoder {
  /// 多帧图片解成会动的 UIImage（每帧缩到 maxPixel 以内，最多 200 帧）；单帧返回 nil。
  static func animated(_ url: URL, maxPixel: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let count = CGImageSourceGetCount(source)
    guard count > 1 else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    var frames: [UIImage] = []
    var total: Double = 0
    for i in 0..<min(count, 200) {
      guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
      frames.append(UIImage(cgImage: cg))
      total += frameDelay(source, i)
    }
    guard frames.count > 1 else { return frames.first }
    return UIImage.animatedImage(with: frames, duration: total)
  }

  /// 一帧的时长：GIF / PNG / WebP 各自的属性，没写或太短时按 0.1 秒（和浏览器一致）。
  private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
    let dicts: [(CFString, CFString, CFString)] = [
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ]
    for (dict, unclamped, clamped) in dicts {
      guard let d = props[dict] as? [CFString: Any] else { continue }
      let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
      return value < 0.011 ? 0.1 : value
    }
    return 0.1
  }

  static func downsampled(_ url: URL, maxPixel: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
  }

  /// 同上，从内存里的数据解（网络图片）。
  static func downsampled(data: Data, maxPixel: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
  }
}

/// 播放 UIImage 动图（SwiftUI 的 Image 不会动）。按图片比例适应给定的空间。
struct AnimatedImageView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView()
    view.contentMode = .scaleAspectFit
    view.clipsToBounds = true
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    return view
  }

  func updateUIView(_ view: UIImageView, context: Context) {
    if view.image !== image {
      view.image = image
      view.startAnimating()
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let w = proposal.width ?? size.width
    let h = proposal.height ?? size.height
    let scale = min(w / size.width, h / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
  }
}

/// 上传 / 下载的进度环：progress 为 nil 时转圈（还不知道进度，例如服务端在从 QQ 拉）。
/// 2026-10-24 用户要求：各阶段用版面表示，不加「下载中 N%」这类说明文字。
struct TransferRing: View {
  let progress: Double?
  var lineWidth: CGFloat = 3

  var body: some View {
    ZStack {
      Circle().stroke(.secondary.opacity(0.25), lineWidth: lineWidth)
      if let progress {
        Circle()
          .trim(from: 0, to: max(0.02, min(1, progress)))
          .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.linear(duration: 0.2), value: progress)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .padding(lineWidth / 2)
    .accessibilityElement()
    .accessibilityLabel("传输进度")
    .accessibilityValue(progress.map { "\(Int($0 * 100))%" } ?? "进行中")
  }
}
