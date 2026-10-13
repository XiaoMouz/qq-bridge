// 附件：选好的照片、视频、文件，粘贴、拖进来的图片，先放进输入框上方的预览条，点发送时才上传、发出。
// 发送时预览条上显示每个的上传进度，发完的从预览条里消失；失败的留着并标红，可以删掉或再点发送重试。
import AVFoundation
import PhotosUI
import QQBridgeKit
import QQBridgeProto
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentLoader {
  /// 相册里选的一项：照片转成 JPEG（长边 2560 以内），视频拷到临时目录并截一帧做预览。
  static func load(_ item: PhotosPickerItem) async -> Attachment? {
    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
      guard let movie = try? await item.loadTransferable(type: MovieFile.self) else { return nil }
      return Attachment(payload: .video(movie.url), preview: await videoFrame(movie.url))
    }
    guard let raw = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: raw) else { return nil }
    return Attachment(payload: .image(ChatScreen.jpeg(image) ?? raw), preview: thumbnail(image))
  }

  /// 文件选择器 / 拖进来的文件：拷到临时目录（选择器给的链接离开作用域就读不到了）。图片、视频按图片、视频发。
  static func load(file url: URL) async -> Attachment? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let copy = dir.appendingPathComponent(url.lastPathComponent)
    guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return nil }
    let type = UTType(filenameExtension: copy.pathExtension)
    if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: copy), let image = UIImage(data: data) {
      // GIF 原样发（转 JPEG 就不会动了）。
      let payload = type?.conforms(to: .gif) == true ? data : (ChatScreen.jpeg(image) ?? data)
      return Attachment(payload: .image(payload), preview: thumbnail(image))
    }
    if type?.conforms(to: .movie) == true {
      return Attachment(payload: .video(copy), preview: await videoFrame(copy))
    }
    return Attachment(payload: .file(copy, name: url.lastPathComponent), preview: nil)
  }

  /// 粘贴：本 App 复制的图片 / 表情直接用服务端的；别处复制的图片当照片发。
  @MainActor static func fromPasteboard() -> Attachment? {
    let pb = UIPasteboard.general
    if let data = pb.data(forPasteboardType: MediaPasteboard.type),
      let payload = try? JSONDecoder().decode(MediaPasteboard.Payload.self, from: data)
    {
      return Attachment(payload: .stored(sha256: payload.sha256, sticker: payload.sticker), preview: pb.image.map(thumbnail))
    }
    if let gif = pb.data(forPasteboardType: UTType.gif.identifier), let image = UIImage(data: gif) {
      return Attachment(payload: .image(gif), preview: thumbnail(image))
    }
    guard let image = pb.image else { return nil }
    return Attachment(payload: .image(ChatScreen.jpeg(image) ?? image.pngData() ?? Data()), preview: thumbnail(image))
  }

  /// 粘贴文件（例如 Mac 上在访达里复制、经 iPhone 镜像粘过来的）：每一项按文件读出来，图片、视频按图片、视频发，其他当文件发。
  @MainActor static func filesFromPasteboard() async -> [Attachment] {
    var out: [Attachment] = []
    for provider in UIPasteboard.general.itemProviders {
      let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
      guard let type = types.first(where: { !$0.conforms(to: .text) && ($0.conforms(to: .data) || $0.conforms(to: .content)) }) else { continue }
      guard let file = await copyFile(provider, type: type) else { continue }
      if let a = await load(file: file) { out.append(a) }
    }
    return out
  }

  /// 把剪贴板里的一项存成临时文件（系统给的文件在回调结束后就删了，要当场拷走）。
  private static func copyFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
    let name = provider.suggestedName.map { name in
      (name as NSString).pathExtension.isEmpty ? name + "." + (type.preferredFilenameExtension ?? "dat") : name
    }
    return await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
      _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else { return done.resume(returning: nil) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(name ?? url.lastPathComponent)
        done.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil)
      }
    }
  }

  static func thumbnail(_ image: UIImage) -> UIImage {
    image.preparingThumbnail(of: CGSize(width: 240, height: 240 * image.size.height / max(image.size.width, 1))) ?? image
  }

  static func videoFrame(_ url: URL) async -> UIImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    guard let frame = try? await generator.image(at: .zero).image else { return nil }
    return UIImage(cgImage: frame)
  }
}

/// 输入框上方的附件预览条。
struct AttachmentTray: View {
  @Bindable var composer: Composer

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(composer.attachments) { a in
          ZStack {
            if let preview = a.preview {
              Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
            } else {
              VStack(spacing: 4) {
                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.tint)
                Text(a.fileName ?? "文件").font(.caption2).lineLimit(2).multilineTextAlignment(.center)
              }
              .padding(6)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.quaternary)
            }
            if case .video = a.payload {
              Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 3)
            }
            switch a.state {
            case .uploading(let p):
              Color.black.opacity(0.35)
              ProgressView(value: max(0.02, p)).progressViewStyle(.circular).tint(.white)
            case .failed:
              Color.red.opacity(0.35)
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            case .ready:
              EmptyView()
            }
          }
          .frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(alignment: .topTrailing) {
            if !isUploading(a) {
              Button { composer.attachments.removeAll { $0.id == a.id } } label: {
                Image(systemName: "xmark.circle.fill")
                  .symbolRenderingMode(.palette)
                  .foregroundStyle(.white, .black.opacity(0.6))
                  .font(.system(size: 18))
              }
              .offset(x: 5, y: -5)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 6)
    }
  }

  private func isUploading(_ a: Attachment) -> Bool {
    if case .uploading = a.state { return true }
    return false
  }
}

/// 拖进会话时盖在聊天页上的提示。
struct DropHint: View {
  var body: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      VStack(spacing: 10) {
        Image(systemName: "arrow.down.doc.fill").font(.system(size: 44)).foregroundStyle(.tint)
        Text("松手发送").font(.title3.bold())
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .padding(12)
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}
