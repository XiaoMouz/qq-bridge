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
  /// 同一会话里可以左右翻的图片（含 target）；空 = 只看这一张。
  var gallery: [MediaTarget] = []
  @Environment(\.dismiss) private var dismiss
  @Environment(AppModel.self) private var model
  @State private var current: String = ""
  @State private var pages: [String: ImagePage] = [:]
  @State private var chrome = true
  /// 下拉关闭的进度（0…1），背景跟着变淡。
  @State private var dragProgress: CGFloat = 0
  @State private var visible = false
  @State private var editing: URL?
  @State private var edited: URL?
  @State private var forwarding: ForwardPayload?
  @State private var toast: String?

  private var items: [MediaTarget] { gallery.contains(where: { $0.id == target.id }) ? gallery : [target] }
  private var page: ImagePage? { pages[current] }
  private var index: Int { items.firstIndex { $0.id == current } ?? 0 }

  var body: some View {
    ZStack {
      // 背景：工具栏显示时是压暗的毛玻璃，单击隐藏后全黑（沉浸）；下拉时变淡。
      Rectangle()
        .fill(chrome ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.black))
        .environment(\.colorScheme, .dark)
        .overlay(Color.black.opacity(chrome ? 0.6 : 0))
        .opacity(visible ? Double(1 - dragProgress * 0.9) : 0)
        .ignoresSafeArea()

      TabView(selection: $current) {
        ForEach(items) { t in
          ImagePageView(page: page(for: t), onTap: { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } },
                        onDrag: { dragProgress = $0 }, onDismiss: close)
            .tag(t.id)
            .ignoresSafeArea()
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .ignoresSafeArea()
      .scaleEffect(visible ? 1 : 0.92)
      .opacity(visible ? 1 : 0)

      if chrome, dragProgress == 0 { overlay.transition(.opacity) }
      if let toast {
        Text(toast).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
          .glassEffect(.regular, in: Capsule())
          .transition(.opacity)
      }
    }
    .statusBarHidden(!chrome)
    .onAppear {
      current = target.id
      withAnimation(.spring(duration: 0.3, bounce: 0.15)) { visible = true }
    }
    .onChange(of: current) { _, id in
      // 翻到哪张加载哪张，顺带预加载左右两张。
      guard let i = items.firstIndex(where: { $0.id == id }) else { return }
      for j in max(0, i - 1)...min(items.count - 1, i + 1) { _ = page(for: items[j]).start() }
    }
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

  private func page(for t: MediaTarget) -> ImagePage {
    if let p = pages[t.id] { return p.start() }
    let p = ImagePage(target: t, session: session, chatId: chatId)
    DispatchQueue.main.async { pages[t.id] = p }
    return p.start()
  }

  private func close() {
    withAnimation(.easeIn(duration: 0.18)) { visible = false } completion: {
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) { dismiss() }
    }
  }

  /// 顶部：页码 + 关闭；底部：原图拿不到的提示 + 工具栏。单击图片隐藏 / 显示。
  private var overlay: some View {
    VStack(spacing: 10) {
      HStack {
        if items.count > 1 {
          Text("\(index + 1) / \(items.count)")
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.45)))
        }
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.black.opacity(0.55)))
            .shadow(color: .black.opacity(0.4), radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
      }
      .padding(.horizontal, 16)
      Spacer()
      if page?.originalFailed == true {
        Text("原图已过期，QQ 上也拿不到了，显示的是缩略图").font(.footnote).foregroundStyle(.white)
          .padding(.horizontal, 14).padding(.vertical, 8)
          .background(Capsule().fill(.black.opacity(0.55)))
      }
      let original = page?.original
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
      .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 24))
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

  // MARK: 动作

  private func save(_ file: URL) async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      show("没有相册权限：请在系统设置里允许 BetterChat 添加照片")
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
        forwarded(to: chat)
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
      if chat == chatId { show("已发送") } else { forwarded(to: chat) }
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

  /// 转发成功：这里提示一句，App 底部也留一条可以点开目标会话的提示（关掉查看器后还在）。
  private func forwarded(to chat: Int64) {
    let name = (try? session.store.dialogItems(limit: 5000))?.first { $0.id == chat }?.title ?? "会话"
    show("已转发到「\(name)」")
    model.showToast(AppToast(text: "已转发到「\(name)」", chatId: chat))
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
  /// 没放大时往下拖：进度 0…1（背景跟着变淡）。
  var onDrag: (CGFloat) -> Void = { _ in }
  /// 拖够了松手：关闭。
  var onDismiss: (() -> Void)? = nil

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
    let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
    pan.delegate = context.coordinator
    scroll.addGestureRecognizer(pan)
    return scroll
  }

  func updateUIView(_ scroll: CenteringScrollView, context: Context) {
    context.coordinator.onTap = onTap
    context.coordinator.onDrag = onDrag
    context.coordinator.onDismiss = onDismiss
    if scroll.imageView.image !== image {
      let keepZoom = scroll.zoomScale > 1 && scroll.imageView.image.map { abs($0.size.width / $0.size.height - image.size.width / image.size.height) < 0.01 } == true
      scroll.imageView.image = image
      scroll.imageView.startAnimating()
      if !keepZoom { scroll.zoomScale = 1 }
      scroll.setNeedsLayout()
    }
  }

  @MainActor final class Coordinator: NSObject, @MainActor UIScrollViewDelegate, @MainActor UIGestureRecognizerDelegate {
    var onTap: () -> Void
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDismiss: (() -> Void)?
    init(onTap: @escaping () -> Void) { self.onTap = onTap }

    /// 下拉关闭只在没放大、明显往下拖时接手（其余交给滚动和左右翻页）。
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
      guard let pan = g as? UIPanGestureRecognizer, let scroll = pan.view as? UIScrollView else { return true }
      guard onDismiss != nil, let centering = scroll as? CenteringScrollView, centering.atTop,
        scroll.zoomScale <= max(1, scroll.minimumZoomScale) + 0.01
      else { return false }
      let v = pan.velocity(in: scroll)
      return v.y > 0 && abs(v.y) > abs(v.x) * 1.3
    }

    @objc func pan(_ g: UIPanGestureRecognizer) {
      guard let scroll = g.view as? CenteringScrollView else { return }
      let t = g.translation(in: scroll)
      let progress = min(1, max(0, t.y / 300))
      switch g.state {
      case .changed:
        let scale = 1 - progress * 0.25
        scroll.imageView.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: scale, y: scale)
        onDrag(progress)
      case .ended where t.y > 120 || g.velocity(in: scroll).y > 900:
        onDismiss?()
      default:
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
          scroll.imageView.transform = .identity
        }
        onDrag(0)
      }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? CenteringScrollView)?.imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? CenteringScrollView)?.center() }

    @objc func singleTap() { onTap() }

    @objc func doubleTap(_ g: UITapGestureRecognizer) {
      guard let scroll = g.view as? CenteringScrollView else { return }
      if abs(scroll.zoomScale - 1) > 0.01 {
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
      // 整块屏幕都能缩放、拖动；没放大时图片放在安全区内（不被刘海、底部横条挡住）。
      let area = bounds.inset(by: safeAreaInsets)
      let fitAll = min(area.width / img.size.width, area.height / img.size.height)
      let fitWidth = area.width / img.size.width
      // 长图（比屏幕细长得多）：按宽度铺满、上下滚动看；双指捏合可以缩小看全貌。
      let isLong = img.size.height / img.size.width > (area.height / area.width) * 1.6
      let fit = isLong ? fitWidth : fitAll
      let size = CGSize(width: img.size.width * fit, height: img.size.height * fit)
      // 缩略图换成原图（同一张图、同样大小）时保持看到的位置；第一次打开长图从顶部开始。
      let ratio = contentSize.height > 0 ? (contentOffset.y + contentInset.top) / contentSize.height : 0
      imageView.frame = CGRect(origin: .zero, size: size)
      contentSize = size
      minimumZoomScale = isLong ? fitAll / fitWidth : 1
      maximumZoomScale = isLong ? 4 : 5
      center()
      if isLong { contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top + ratio * size.height) }
    }
    center()
  }

  /// 图片比屏幕小时放在正中间；比屏幕高（长图、放大后）上下留出刘海和底部横条的位置。
  func center() {
    let safe = safeAreaInsets
    let w = max((bounds.width - imageView.frame.width) / 2, 0)
    let fitsVertically = imageView.frame.height <= bounds.height - safe.top - safe.bottom
    let h = max((bounds.height - imageView.frame.height) / 2, 0)
    contentInset = fitsVertically
      ? UIEdgeInsets(top: h, left: w, bottom: h, right: w)
      : UIEdgeInsets(top: safe.top, left: w, bottom: safe.bottom, right: w)
  }

  /// 在最顶上（长图滚到头、或者没放大）：这时往下拖才是关闭。
  var atTop: Bool { contentOffset.y <= -contentInset.top + 1 }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    laidOutSize = .zero
    setNeedsLayout()
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

/// 一张图的加载状态：先显示缩略图 / 预览图，原图到了换上。
@MainActor
@Observable
final class ImagePage {
  let target: MediaTarget
  private let session: Session
  private let chatId: Int64
  var image: UIImage?
  var original: (sha256: String, file: URL)?
  var originalFailed = false
  private var started = false

  init(target: MediaTarget, session: Session, chatId: Int64) {
    self.target = target
    self.session = session
    self.chatId = chatId
  }

  @discardableResult
  func start() -> ImagePage {
    guard !started else { return self }
    started = true
    Task { await load() }
    return self
  }

  private func load() async {
    let media = target.media
    let placeholder = media.previewSha256.isEmpty ? media.thumbSha256 : media.previewSha256
    if !placeholder.isEmpty, let file = try? await session.media.file(for: placeholder, chatId: chatId) {
      image = await Self.decode(file)
    }
    // 原图：服务端还在下载就等它推「下好了」（先登记再请求，不会漏）；没等到（断线）再问一次兜底。
    // 只有确实拿不到（过期、失败）才提示。
    let watch = target.seq > 0 ? MediaReady.shared.watch(chatId: target.chatId, seq: target.seq, ord: media.ord, thumb: false) : nil
    var found: (String, URL)?
    for attempt in 0..<6 {
      if Task.isCancelled { return }
      switch await originalSha() {
      case .ready(let sha):
        if let file = try? await session.media.file(for: sha, chatId: chatId) {
          found = (sha, file)
        } else if attempt >= 2 {
          originalFailed = true
          return
        }
      case .gone:
        originalFailed = true
        return
      case .waiting:
        if let event = await watch?.next() {
          if event.state != "stored" {
            originalFailed = true
            return
          }
          if let file = try? await session.media.file(for: event.sha256, chatId: chatId) { found = (event.sha256, file) }
        }
      }
      if found != nil { break }
    }
    guard let (sha, file) = found else {
      originalFailed = true
      return
    }
    if let full = await Self.decode(file) { image = full }
    original = (sha, file)
  }

  enum OriginalState {
    case ready(String)
    /// 服务端还在下载（或这次请求出错了），等会儿再问。
    case waiting
    /// 过期、失败，QQ 上也拿不到了。
    case gone
  }

  /// 原图的 sha256：服务端有（或能从 QQ 拉回）就直接用；从没下过的先让服务端当场从 QQ 拉。
  private func originalSha() async -> OriginalState {
    let media = target.media
    if !media.sha256.isEmpty { return .ready(media.sha256) }
    guard target.seq > 0 else { return .gone }
    var ref = Qqbridge_V1_MediaRef()
    ref.chatID = target.chatId
    ref.seq = target.seq
    ref.ord = media.ord
    var req = Qqbridge_V1_RequestMediaRequest()
    req.refs = [ref]
    req.original = true
    guard let res = try? await session.api.media.requestMedia(request: req, headers: session.api.headers).get(), let got = res.media.first else {
      return .waiting
    }
    if got.state == .stored, !got.sha256.isEmpty { return .ready(got.sha256) }
    switch got.state {
    case .expired, .failed, .skipped: return .gone
    default: return .waiting
    }
  }

  nonisolated static func decode(_ file: URL) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      if let moving = ImageDecoder.animated(file, maxPixel: 2048) { return moving }
      // 超大图缩到 4096 以内再显示，避免占满内存。
      return ImageDecoder.downsampled(file, maxPixel: 4096)
    }.value
  }
}

/// 全屏的一页：整块屏幕都能缩放、拖动；没放大时往下拖关闭。
struct ImagePageView: View {
  let page: ImagePage
  let onTap: () -> Void
  let onDrag: (CGFloat) -> Void
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      if let image = page.image {
        ZoomableImage(image: image, onTap: onTap, onDrag: onDrag, onDismiss: onDismiss)
      }
      if page.original == nil, !page.originalFailed {
        ProgressView().tint(.white).controlSize(.large)
      }
    }
  }
}
