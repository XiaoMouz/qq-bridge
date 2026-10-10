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
    cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
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
  @ViewBuilder var placeholder: () -> Placeholder
  @Environment(\.session) private var session
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable()
      } else {
        placeholder()
      }
    }
    .task(id: sha256) { await load() }
  }

  private func load() async {
    guard let sha256, !sha256.isEmpty, let session else {
      image = nil
      return
    }
    let key = maxPixel.map { "\(sha256)@\(Int($0))" } ?? sha256
    if let hit = ImageMemoryCache.shared.get(key) {
      image = hit
      return
    }
    do {
      let file = try await session.media.file(for: sha256, chatId: chatId)
      let limit = maxPixel
      let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
        if let limit { return ImageDecoder.downsampled(file, maxPixel: limit) }
        guard let img = UIImage(contentsOfFile: file.path) else { return nil }
        return await img.byPreparingForDisplay() ?? img
      }.value
      if let decoded {
        ImageMemoryCache.shared.set(key, decoded)
        image = decoded
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
}
