// 看大图：先显示缩略图，原图到了自动换上；双指缩放、双击放大、拖动、居中；单击隐藏 / 显示工具栏；
// 底部：转发、编辑（系统标注）、保存到相册、分享。
import PencilKit
import Photos
import QQBridgeKit
import QQBridgeProto
import SwiftUI
import UIKit

struct ImageViewer: View {
  let target: MediaTarget
  let session: Session
  let chatId: Int64
  @Environment(\.dismiss) private var dismiss
  @State private var image: UIImage?
  @State private var original: (sha256: String, file: URL)?
  @State private var originalFailed = false
  @State private var chrome = true
  @State private var editing: URL?
  @State private var edited: URL?
  @State private var forwarding: ForwardPayload?
  @State private var toast: String?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if let image {
        ZoomableImage(image: image, onTap: { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } })
          .ignoresSafeArea()
      }
      if original == nil, !originalFailed {
        ProgressView().tint(.white).controlSize(.large)
      }
      if chrome { overlay.transition(.opacity) }
      if let toast {
        Text(toast).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
          .glassEffect(.regular, in: Capsule())
          .transition(.opacity)
      }
    }
    .statusBarHidden(!chrome)
    .task { await load() }
    .fullScreenCover(item: Binding(get: { editing.map(IdentifiedURL.init) }, set: { editing = $0?.url })) { item in
      MarkupEditor(url: item.url) { result in
        editing = nil
        edited = result
      }
    }
    .confirmationDialog("编辑好的图片", isPresented: Binding(get: { edited != nil }, set: { if !$0 { edited = nil } }), titleVisibility: .visible) {
      if let url = edited {
        Button("发送到这个聊天") { Task { await sendEdited(url, to: chatId) } }
        Button("转发给…") { forwarding = .file(url) }
        Button("保存到相册") { Task { await save(url) } }
      }
    }
    .sheet(item: $forwarding) { payload in
      ChatPicker(session: session) { chat in
        forwarding = nil
        Task { await forward(payload, to: chat) }
      }
    }
  }

  private var overlay: some View {
    VStack {
      HStack {
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36) }
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
      }
      .padding(.horizontal)
      Spacer()
      if originalFailed {
        Text("原图已过期，QQ 上也拿不到了，显示的是缩略图").font(.footnote).foregroundStyle(.white)
          .padding(.horizontal, 14).padding(.vertical, 8)
          .glassEffect(.regular, in: Capsule())
      }
      HStack(spacing: 0) {
        toolButton("转发", "arrowshape.turn.up.right") {
          if let original { forwarding = .sha(original.sha256) }
        }
        toolButton("编辑", "pencil.tip.crop.circle") {
          if let original { editing = editableCopy(original.file) }
        }
        toolButton("保存", "square.and.arrow.down") {
          if let original { Task { await save(original.file) } }
        }
        if let original {
          ShareLink(item: original.file) { toolLabel("分享", "square.and.arrow.up") }
            .frame(maxWidth: .infinity)
        } else {
          toolLabel("分享", "square.and.arrow.up").frame(maxWidth: .infinity).opacity(0.4)
        }
      }
      .padding(.vertical, 8)
      .glassEffect(.regular, in: .rect(cornerRadius: 24))
      .padding(.horizontal)
      .disabled(original == nil)
      .opacity(original == nil ? 0.5 : 1)
    }
    .tint(.white)
  }

  private func toolButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { toolLabel(title, icon) }.frame(maxWidth: .infinity)
  }

  private func toolLabel(_ title: String, _ icon: String) -> some View {
    VStack(spacing: 4) {
      Image(systemName: icon).font(.title3)
      Text(title).font(.caption2)
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, minHeight: 44)
  }

  // MARK: 加载

  private func load() async {
    let media = target.media
    let placeholder = media.previewSha256.isEmpty ? media.thumbSha256 : media.previewSha256
    if !placeholder.isEmpty, let file = try? await session.media.file(for: placeholder, chatId: chatId) {
      image = await decode(file)
    }
    guard let sha = await originalSha() else {
      originalFailed = true
      return
    }
    guard let file = try? await session.media.file(for: sha, chatId: chatId) else {
      originalFailed = true
      return
    }
    if let full = await decode(file) { image = full }
    original = (sha, file)
  }

  /// 原图的 sha256：服务端有（或能从 QQ 拉回）就直接用；从没下过的先让服务端当场从 QQ 拉。
  private func originalSha() async -> String? {
    let media = target.media
    if !media.sha256.isEmpty { return media.sha256 }
    guard target.seq > 0 else { return nil }
    var ref = Qqbridge_V1_MediaRef()
    ref.chatID = target.chatId
    ref.seq = target.seq
    ref.ord = media.ord
    var req = Qqbridge_V1_RequestMediaRequest()
    req.refs = [ref]
    req.original = true
    let res = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get()
    guard let got = res?.media.first, got.state == .stored, !got.sha256.isEmpty else { return nil }
    return got.sha256
  }

  private func decode(_ file: URL) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      if let moving = ImageDecoder.animated(file, maxPixel: 2048) { return moving }
      // 超大图缩到 4096 以内再显示，避免占满内存。
      return ImageDecoder.downsampled(file, maxPixel: 4096)
    }.value
  }

  // MARK: 动作

  private func save(_ file: URL) async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      show("没有相册权限：请在系统设置里允许 QQ Bridge 添加照片")
      return
    }
    let named = editableCopy(file)
    do {
      try await PhotoSaver.add(named)
      show("已保存到相册")
    } catch {
      show("保存失败：\(error.localizedDescription)")
    }
  }

  private func forward(_ payload: ForwardPayload, to chat: Int64) async {
    switch payload {
    case .sha(let sha):
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.image.sha256 = sha
      do {
        try await session.sender.send(chatId: chat, segments: [seg])
        show("已转发")
      } catch {
        show("转发失败：\(error.localizedDescription)")
      }
    case .file(let url):
      await sendEdited(url, to: chat)
    }
  }

  private func sendEdited(_ url: URL, to chat: Int64) async {
    do {
      let data = try Data(contentsOf: url)
      let uploaded = try await session.api.upload(data, mime: ImageFile.mime(of: url), name: url.lastPathComponent)
      var seg = Qqbridge_V1_OutgoingSegment()
      seg.image.sha256 = uploaded.sha256
      try await session.sender.send(chatId: chat, segments: [seg])
      show(chat == chatId ? "已发送" : "已转发")
    } catch {
      show("发送失败：\(error.localizedDescription)")
    }
  }

  /// 缓存里的文件没有扩展名：拷一份带扩展名的（相册、标注编辑都靠扩展名认类型）。
  private func editableCopy(_ file: URL) -> URL {
    let ext = ImageFile.ext(of: file)
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("qqbridge-\(file.lastPathComponent).\(ext)")
    if !FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.copyItem(at: file, to: dest) }
    return dest
  }

  private func show(_ text: String) {
    withAnimation { toast = text }
    Task {
      try? await Task.sleep(for: .seconds(2))
      withAnimation { if toast == text { toast = nil } }
    }
  }
}

enum ForwardPayload: Identifiable {
  case sha(String)
  case file(URL)
  var id: String {
    switch self {
    case .sha(let s): s
    case .file(let u): u.path
    }
  }
}

struct IdentifiedURL: Identifiable {
  let url: URL
  var id: String { url.path }
}

/// 按文件头认图片类型。
enum ImageFile {
  static func ext(of url: URL) -> String {
    guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 12) else { return "jpg" }
    let b = [UInt8](d)
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
    if b.count >= 12, b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
    if b.count >= 12, String(bytes: b[4...7], encoding: .ascii) == "ftyp" { return "heic" }
    return url.pathExtension.isEmpty ? "jpg" : url.pathExtension
  }

  static func mime(of url: URL) -> String {
    switch ext(of: url) {
    case "png": "image/png"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "heic": "image/heic"
    default: "image/jpeg"
    }
  }
}

// MARK: - 缩放

/// UIScrollView 做的缩放：双指缩放（最多 5 倍）、双击放大到点击处 / 还原、放大后拖动，图片始终居中。
struct ZoomableImage: UIViewRepresentable {
  let image: UIImage
  var onTap: () -> Void = {}

  func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

  func makeUIView(context: Context) -> CenteringScrollView {
    let scroll = CenteringScrollView()
    scroll.delegate = context.coordinator
    scroll.maximumZoomScale = 5
    scroll.minimumZoomScale = 1
    scroll.showsVerticalScrollIndicator = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.backgroundColor = .clear
    scroll.imageView.contentMode = .scaleAspectFit
    scroll.addSubview(scroll.imageView)
    let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
    double.numberOfTapsRequired = 2
    let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
    single.require(toFail: double)
    scroll.addGestureRecognizer(double)
    scroll.addGestureRecognizer(single)
    return scroll
  }

  func updateUIView(_ scroll: CenteringScrollView, context: Context) {
    context.coordinator.onTap = onTap
    if scroll.imageView.image !== image {
      let keepZoom = scroll.zoomScale > 1 && scroll.imageView.image.map { abs($0.size.width / $0.size.height - image.size.width / image.size.height) < 0.01 } == true
      scroll.imageView.image = image
      scroll.imageView.startAnimating()
      if !keepZoom { scroll.zoomScale = 1 }
      scroll.setNeedsLayout()
    }
  }

  @MainActor final class Coordinator: NSObject, @MainActor UIScrollViewDelegate {
    var onTap: () -> Void
    init(onTap: @escaping () -> Void) { self.onTap = onTap }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? CenteringScrollView)?.imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? CenteringScrollView)?.center() }

    @objc func singleTap() { onTap() }

    @objc func doubleTap(_ g: UITapGestureRecognizer) {
      guard let scroll = g.view as? CenteringScrollView else { return }
      if scroll.zoomScale > 1 {
        scroll.setZoomScale(1, animated: true)
      } else {
        let p = g.location(in: scroll.imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
      }
    }
  }
}

final class CenteringScrollView: UIScrollView {
  let imageView = UIImageView()
  private var laidOutSize: CGSize = .zero

  override func layoutSubviews() {
    super.layoutSubviews()
    // 尺寸变了（首次布局、转屏、换成原图）：图片按比例铺满可见区域。
    let key = CGSize(width: bounds.width, height: bounds.height * 1000 + (imageView.image?.size.width ?? 0))
    if zoomScale == 1, key != laidOutSize, let img = imageView.image, img.size.width > 0, img.size.height > 0 {
      laidOutSize = key
      let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
      let size = CGSize(width: img.size.width * fit, height: img.size.height * fit)
      imageView.frame = CGRect(origin: .zero, size: size)
      contentSize = size
    }
    center()
  }

  /// 图片比可见区域小时放在正中间。
  func center() {
    let w = max((bounds.width - imageView.frame.width) / 2, 0)
    let h = max((bounds.height - imageView.frame.height) / 2, 0)
    contentInset = UIEdgeInsets(top: h, left: w, bottom: h, right: w)
  }
}

// MARK: - 编辑

/// 在图上画（PencilKit 的画笔、马克笔、橡皮擦、撤销），完成后把图和笔迹合成一张 PNG 交回。
struct MarkupEditor: View {
  let url: URL
  let onDone: (URL?) -> Void
  @State private var image: UIImage?
  @State private var canvas = PKCanvasView()

  var body: some View {
    NavigationStack {
      GeometryReader { geo in
        if let image {
          let fit = Self.fit(image.size, in: geo.size)
          ZStack {
            Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height)
            CanvasView(canvas: canvas).frame(width: fit.width, height: fit.height)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Color.black)
      .navigationTitle("编辑")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { onDone(nil) } }
        ToolbarItem(placement: .confirmationAction) { Button("完成") { onDone(render()) } }
        ToolbarItemGroup(placement: .bottomBar) {
          Button("撤销", systemImage: "arrow.uturn.backward") { canvas.undoManager?.undo() }
          Button("重做", systemImage: "arrow.uturn.forward") { canvas.undoManager?.redo() }
        }
      }
    }
    .task { image = UIImage(contentsOfFile: url.path) }
  }

  private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return box }
    let scale = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
  }

  /// 原图尺寸合成：笔迹按显示大小和原图的比例放大。
  private func render() -> URL? {
    guard let image else { return nil }
    let shown = canvas.bounds.size
    guard shown.width > 0 else { return nil }
    let scale = image.size.width / shown.width
    let drawing = canvas.drawing.image(from: CGRect(origin: .zero, size: shown), scale: scale * image.scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    let out = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
      drawing.draw(in: CGRect(origin: .zero, size: image.size))
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(UUID().uuidString).png")
    guard let data = out.pngData(), (try? data.write(to: file)) != nil else { return nil }
    return file
  }
}

private struct CanvasView: UIViewRepresentable {
  let canvas: PKCanvasView

  func makeUIView(context: Context) -> PKCanvasView {
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.drawingPolicy = .anyInput
    canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
    context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
    context.coordinator.picker.addObserver(canvas)
    DispatchQueue.main.async { canvas.becomeFirstResponder() }
    return canvas
  }

  func updateUIView(_ view: PKCanvasView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    let picker = PKToolPicker()
  }
}

// MARK: - 选会话

/// 转发：选一个会话（可搜索；置顶在前，其余按最近）。
struct ChatPicker: View {
  let session: Session
  let onPick: (Int64) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var items: [DialogItem] = []
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List(filtered) { item in
        Button { onPick(item.id) } label: {
          HStack(spacing: 12) {
            AvatarView(sha256: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID, size: 40)
            Text(item.title).lineLimit(1).foregroundStyle(.primary)
            Spacer()
            if item.dialog.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      .listStyle(.plain)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索会话")
      .navigationTitle("转发给")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
      .task {
        do {
          for try await list in session.store.observeDialogs() { items = list }
        } catch {}
      }
    }
  }

  private var filtered: [DialogItem] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return items }
    return items.filter { $0.title.localizedCaseInsensitiveContains(q) || String($0.dialog.peerID).contains(q) }
  }
}

/// 写相册：performChanges 的闭包在 Photos 的后台队列上跑，不能带主线程隔离（否则 Swift 6 运行时断言崩溃）。
enum PhotoSaver {
  nonisolated static func add(_ file: URL) async throws {
    try await PHPhotoLibrary.shared().performChanges { @Sendable in
      PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
    }
  }
}
