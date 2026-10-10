// 媒体显示：头像、缩略图。图片经 MediaCache（按 sha256 缓存、有上限）加载，内存里再放一层小缓存，滚动时不反复解码。
import QQBridgeKit
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
    if let hit = ImageMemoryCache.shared.get(sha256) {
      image = hit
      return
    }
    do {
      let file = try await session.media.file(for: sha256, chatId: chatId)
      let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
        guard let img = UIImage(contentsOfFile: file.path) else { return nil }
        return await img.byPreparingForDisplay() ?? img
      }.value
      if let decoded {
        ImageMemoryCache.shared.set(sha256, decoded)
        image = decoded
      }
    } catch {
      image = nil
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
