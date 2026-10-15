// 看大图：先显示缩略图，原图到了自动换上；双指缩放、双击放大、拖动、居中；单击隐藏 / 显示工具栏；
// 底部：转发、保存、分享；手机端另有编辑（系统标注）。
#if !targetEnvironment(macCatalyst)
import PencilKit
#endif
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
  #if targetEnvironment(macCatalyst)
  @Environment(\.macMediaWindow) private var mediaWindow
  #endif
  @Environment(AppModel.self) private var model
  @State private var current: String = ""
  @State private var pages: [String: ImagePage] = [:]
  @State private var chrome = true
  /// 下拉关闭的进度（0…1），背景跟着变淡。
  @State private var dragProgress: CGFloat = 0
  @State private var visible = false
  #if !targetEnvironment(macCatalyst)
  @State private var editing: URL?
  @State private var edited: URL?
  #endif
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
    #if targetEnvironment(macCatalyst)
    .background(MacMediaKeyboard(close: close, previous: { movePage(-1) }, next: { movePage(1) }))
    #endif
    .onAppear {
      current = target.id
      withAnimation(.spring(duration: 0.3, bounce: 0.15)) { visible = true }
    }
    .onChange(of: current) { _, id in
      // 翻到哪张加载哪张，顺带预加载左右两张。
      guard let i = items.firstIndex(where: { $0.id == id }) else { return }
      for j in max(0, i - 1)...min(items.count - 1, i + 1) { _ = page(for: items[j]).start() }
    }
    #if !targetEnvironment(macCatalyst)
    .platformFullScreenCover(item: Binding(get: { editing.map(IdentifiedURL.init) }, set: { editing = $0?.url })) { item in
      MarkupEditor(url: item.url) { result in
        editing = nil
        edited = result
      }
    }
    .confirmationDialog("编辑好的图片", isPresented: Binding(get: { edited != nil }, set: { if !$0 { edited = nil } }), titleVisibility: .visible) {
      if let url = edited {
        Button("发送到这个聊天") { Task { await sendEdited(url, to: chatId) } }
        Button("转发给…") { forwarding = .file(url) }
        Button("保存到相册") { Task { await saveToPhotos(url) } }
      }
    }
    #endif
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
    #if targetEnvironment(macCatalyst)
    if let mediaWindow { mediaWindow.close(); return }
    #endif
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
          #if targetEnvironment(macCatalyst)
          Button("上一张", systemImage: "chevron.left") { movePage(-1) }
            .labelStyle(.iconOnly)
            .disabled(index == 0)
            .help("上一张（←）")
          #endif
          Text("\(index + 1) / \(items.count)")
            .font(.subheadline.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.45)))
          #if targetEnvironment(macCatalyst)
          Button("下一张", systemImage: "chevron.right") { movePage(1) }
            .labelStyle(.iconOnly)
            .disabled(index == items.count - 1)
            .help("下一张（→）")
          #endif
        }
        Spacer()
        if showsCloseButton { Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.black.opacity(0.55)))
            .shadow(color: .black.opacity(0.4), radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        #if targetEnvironment(macCatalyst)
        .help("关闭（Esc）")
        #endif
        }
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
        #if !targetEnvironment(macCatalyst)
        toolButton("编辑", "pencil.tip.crop.circle") {
          if let original { editing = editableCopy(original.file) }
        }
        #endif
        toolButton("保存", "square.and.arrow.down") {
          if let original { Task { await save(original.file) } }
        }
        #if targetEnvironment(macCatalyst)
        .contextMenu {
          Button("保存到相册") {
            if let original { Task { await saveToPhotos(original.file) } }
          }
        }
        .help("保存到设置中的下载目录；右键可保存到相册")
        #endif
        if let original {
          #if targetEnvironment(macCatalyst)
          // 缓存文件没有扩展名，Mac 分享 / 拷贝会被当成普通文件；系统真正要文件时才拷带扩展名的副本。
          ShareLink(item: MacShareImage(sha256: original.sha256, source: original.file), preview: SharePreview("图片")) {
            toolLabel("分享", "square.and.arrow.up")
          }
          .frame(maxWidth: .infinity)
          #else
          ShareLink(item: original.file) { toolLabel("分享", "square.and.arrow.up") }
            .frame(maxWidth: .infinity)
          #endif
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

  private var showsCloseButton: Bool {
    #if targetEnvironment(macCatalyst)
    mediaWindow == nil
    #else
    true
    #endif
  }

  #if targetEnvironment(macCatalyst)
  private func movePage(_ offset: Int) {
    let next = index + offset
    guard items.indices.contains(next) else { return }
    withAnimation(.easeInOut(duration: 0.2)) { current = items[next].id }
  }
  #endif

  private func save(_ file: URL) async {
    #if targetEnvironment(macCatalyst)
    do {
      let name = "\(file.deletingPathExtension().lastPathComponent).\(ImageFile.ext(of: file))"
      let saved = try await MacDownloads.shared.export(file, name: name)
      show("已保存到 \(saved.deletingLastPathComponent().path)")
    } catch {
      show("保存失败：\(error.localizedDescription)")
    }
    #else
    await saveToPhotos(file)
    #endif
  }

  private func saveToPhotos(_ file: URL) async {
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
      #if targetEnvironment(macCatalyst)
      // 2026-10-15 实测：Mac 窗口可以很矮（440×480 时可见区接近正方形），只和窗口比例比较会把
      // 360×640 这类普通竖照判成长图、按宽铺满裁掉上下。桌面上再要求图片本身足够细长（高宽比 > 2.5），
      // 普通竖照始终完整显示（可双击放大），真正的长截图仍按宽度上下滚动。
      let isLong = img.size.height / img.size.width > 2.5
        && img.size.height / img.size.width > (area.height / area.width) * 1.6
      #else
      let isLong = img.size.height / img.size.width > (area.height / area.width) * 1.6
      #endif
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

#if !targetEnvironment(macCatalyst)
/// 在图上画（PencilKit 的画笔、马克笔、橡皮擦、撤销），完成后把图和笔迹合成一张 PNG 交回。
struct MarkupEditor: View {
  let url: URL
  let onDone: (URL?) -> Void
  @State private var image: UIImage?
  /// 笔迹固定在原图比例的逻辑坐标里（见 MarkupCanvas.swift），窗口宽窄变化不会让笔迹和图片错位。
  @State private var canvas = MarkupCanvasView()

  var body: some View {
    NavigationStack {
      GeometryReader { geo in
        if let image {
          let fit = Self.fit(image.size, in: geo.size)
          ZStack {
            Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height)
            CanvasView(canvas: canvas, imageSize: image.size, onCancel: { onDone(nil) }).frame(width: fit.width, height: fit.height)
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

  /// 原图尺寸合成：按画布固定的逻辑矩形渲染笔迹，与导出时的窗口大小无关。
  private func render() -> URL? {
    guard let image, let out = canvas.renderedImage(over: image) else { return nil }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(UUID().uuidString).png")
    guard let data = out.pngData(), (try? data.write(to: file)) != nil else { return nil }
    return file
  }
}

private struct CanvasView: UIViewRepresentable {
  let canvas: MarkupCanvasView
  let imageSize: CGSize
  var onCancel: (() -> Void)?

  func makeUIView(context: Context) -> MarkupCanvasView {
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.drawingPolicy = .anyInput
    canvas.imageSize = imageSize
    canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 6)
    context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
    context.coordinator.picker.addObserver(canvas)
    DispatchQueue.main.async { canvas.becomeFirstResponder() }
    return canvas
  }

  func updateUIView(_ view: MarkupCanvasView, context: Context) {
    // 只改 UIKit 属性：尺寸相同不会重设；缩放在画布自己的 layoutSubviews 里按实际 bounds 计算。
    view.imageSize = imageSize
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    let picker = PKToolPicker()
  }
}
#endif

// MARK: - 选会话

/// 转发：选一个会话（置顶在前，其余按最近）。搜索时除了已有的会话，也搜全部好友和群聊（没有会话的选中时新建）。
struct ChatPicker: View {
  let session: Session
  var title = "转发给"
  var onCancel: (() -> Void)? = nil
  let onPick: (Int64) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var items: [DialogItem] = []
  @State private var query = ""
  @State private var friends: [Qqbridge_V1_Peer] = []
  @State private var groups: [Qqbridge_V1_Peer] = []
  @State private var contactsLoaded = false
  @State private var avatars = AvatarBook()
  #if targetEnvironment(macCatalyst)
  @State private var openRequest = MacChatOpenRequest()
  #else
  @State private var opening: Int64?
  #endif
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        if !q.isEmpty, filtered.isEmpty, matchedFriends.isEmpty, matchedGroups.isEmpty, contactsLoaded {
          Text("没有找到").foregroundStyle(.secondary)
        }
        Section {
          ForEach(filtered) { item in
            Button { onPick(item.id) } label: {
              row(sha: item.peer?.avatarSha256, title: item.title, seed: item.dialog.peerID, pinned: item.dialog.pinned, loading: false)
            }
          }
        } header: {
          if !q.isEmpty { Text("会话") }
        }
        if !matchedFriends.isEmpty {
          Section("好友") {
            ForEach(matchedFriends, id: \.peerID) { p in
              Button { choose(.friend, p.peerID) } label: {
                row(sha: p.avatarSha256.isEmpty ? avatars.sha256[p.peerID] : p.avatarSha256, title: p.remark.isEmpty ? p.name : "\(p.remark)（\(p.name)）", seed: p.peerID, pinned: false, loading: isOpening(.friend, p.peerID))
              }
              .onAppear { if p.avatarSha256.isEmpty { avatars.want(p.peerID, session: session) } }
            }
          }
        }
        if !matchedGroups.isEmpty {
          Section("群聊") {
            ForEach(matchedGroups, id: \.peerID) { p in
              Button { choose(.group, p.peerID) } label: {
                row(sha: p.avatarSha256.isEmpty ? avatars.groupSha256[p.peerID] : p.avatarSha256, title: p.name, seed: p.peerID, pinned: false, loading: isOpening(.group, p.peerID))
              }
              .onAppear { if p.avatarSha256.isEmpty { avatars.wantGroup(p.peerID, session: session) } }
            }
          }
        }
        if !q.isEmpty, !contactsLoaded {
          HStack { Spacer(); ProgressView(); Spacer() }
        }
      }
      .listStyle(.plain)
      .disabled(isOpening)
      .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索会话、好友、群聊")
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", action: cancel)
            #if targetEnvironment(macCatalyst)
            .keyboardShortcut(.cancelAction)
            #endif
        }
      }
      .alert("打不开这个会话", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }), presenting: error) { _ in
        Button("好") { error = nil }
      } message: { Text($0) }
      .task {
        do {
          for try await list in session.store.observeDialogs() { items = list }
        } catch {}
      }
      // 好友、群聊列表一打开就在后台拉（搜索时直接用）。
      .task { await loadContacts() }
      #if targetEnvironment(macCatalyst)
      .onDisappear { openRequest.cancel() }
      .onChange(of: query) { _, _ in openRequest.cancel() }
      #endif
    }
  }

  private func row(sha: String?, title: String, seed: Int64, pinned: Bool, loading: Bool) -> some View {
    HStack(spacing: 12) {
      AvatarView(sha256: sha, title: title, seed: seed, size: 40)
      Text(title).lineLimit(1).foregroundStyle(.primary)
      Spacer()
      if loading {
        ProgressView()
      } else if pinned {
        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var q: String { query.trimmingCharacters(in: .whitespaces) }

  private var filtered: [DialogItem] {
    guard !q.isEmpty else { return items }
    return items.filter { $0.title.localizedCaseInsensitiveContains(q) || String($0.dialog.peerID).contains(q) }
  }

  /// 已经在会话列表里的（搜索结果里不再重复列）。
  private var dialogPeers: Set<String> {
    Set(items.map { "\($0.dialog.scene == .group ? "g" : "u")\($0.dialog.peerID)" })
  }

  private var matchedFriends: [Qqbridge_V1_Peer] {
    guard !q.isEmpty else { return [] }
    let seen = dialogPeers
    return friends.filter { p in
      !seen.contains("u\(p.peerID)")
        && (p.name.localizedCaseInsensitiveContains(q) || p.remark.localizedCaseInsensitiveContains(q) || String(p.peerID).contains(q))
    }
    .prefix(50).map { $0 }
  }

  private var matchedGroups: [Qqbridge_V1_Peer] {
    guard !q.isEmpty else { return [] }
    let seen = dialogPeers
    return groups.filter { p in
      !seen.contains("g\(p.peerID)") && (p.name.localizedCaseInsensitiveContains(q) || String(p.peerID).contains(q))
    }
    .prefix(50).map { $0 }
  }

  private func loadContacts() async {
    let api = session.api
    async let f = try? api.contacts.listFriends(request: .init(), headers: api.headers).get().friends
    async let g = try? api.contacts.listGroups(request: .init(), headers: api.headers).get().groups
    friends = await f ?? []
    groups = await g ?? []
    contactsLoaded = true
  }

  /// 没有会话的好友 / 群：先让服务端建会话，再交出会话 id。
  private func choose(_ scene: Qqbridge_V1_Scene, _ peerId: Int64) {
    #if targetEnvironment(macCatalyst)
    // 取消选择不能被迟到的建会话结果反转；图片、消息和群文件共用此入口。
    error = nil
    openRequest.start(peerKey: "\(scene.rawValue):\(peerId)", operation: {
      try await DialogActions.openChat(session, scene: scene, peerId: peerId)
    }, opened: { onPick($0) }, failed: { error = LoadState.describe($0) })
    #else
    Task { await pick(scene, peerId) }
    #endif
  }

  private var isOpening: Bool {
    #if targetEnvironment(macCatalyst)
    openRequest.peerKey != nil
    #else
    opening != nil
    #endif
  }

  private func isOpening(_ scene: Qqbridge_V1_Scene, _ peerId: Int64) -> Bool {
    #if targetEnvironment(macCatalyst)
    openRequest.peerKey == "\(scene.rawValue):\(peerId)"
    #else
    opening == peerId
    #endif
  }

  private func cancel() {
    #if targetEnvironment(macCatalyst)
    // 点击取消时立即失效，不等表单关闭动画结束才阻止回调。
    openRequest.cancel()
    if let onCancel {
      onCancel()
      return
    }
    #endif
    dismiss()
  }

  #if !targetEnvironment(macCatalyst)
  private func pick(_ scene: Qqbridge_V1_Scene, _ peerId: Int64) async {
    opening = peerId
    defer { opening = nil }
    do {
      onPick(try await DialogActions.openChat(session, scene: scene, peerId: peerId))
    } catch {
      self.error = LoadState.describe(error)
    }
  }
  #endif
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
