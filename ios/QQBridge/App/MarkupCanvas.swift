// 标注画布：笔迹固定记录在原图比例的逻辑坐标里，视图尺寸变化只改缩放，不改笔迹。
//
// 2026-10-14 Mac 实测：窄窗口画的笔迹在窗口变宽后留在旧的点坐标上，和图片错位，导出也跟着错。
// 原因是画布 frame 随窗口 fit 变化，而 PKDrawing 的坐标是画布点坐标。
// 做法参照 Apple 官方示例 PencilKitDraw（DrawingViewController.viewDidLayoutSubviews /
// updateContentSizeForDrawing）：固定逻辑宽度，布局时把 minimum / maximum / zoomScale 设为
// bounds.width / 逻辑宽，contentSize 设为逻辑尺寸 × zoomScale，并把内容滚回原点。
// 笔迹、撤销重做历史都停留在逻辑坐标里，导出按固定的逻辑矩形渲染，与当时窗口大小无关。
import PencilKit
import UIKit

@MainActor
final class MarkupCanvasView: PKCanvasView {
  /// 逻辑坐标的长边。与官方示例的 canvasWidth（768）同量级：常见窗口下缩放在 0.5–1.5 之间，
  /// 画笔粗细与改动前接近；笔迹粗细随图片一起缩放，相对原图保持不变。
  static let logicalLongSide: CGFloat = 768

  /// 原图尺寸（只用来取宽高比）。设定后逻辑尺寸固定，之后的窗口变化只改缩放。
  var imageSize: CGSize = .zero {
    didSet {
      guard imageSize != oldValue else { return }
      logicalSize = Self.logicalSize(for: imageSize)
      fittedBounds = nil
      setNeedsLayout()
    }
  }
  /// 笔迹所在的坐标空间；导出与测试都按它计算。
  private(set) var logicalSize: CGSize = .zero
  /// 上次完成适配时的视图尺寸；尺寸不变的布局回调不重复改缩放。
  private var fittedBounds: CGSize?
  /// 改 zoomScale 会再次触发 layoutSubviews，用它挡住重入。
  private var fitting = false

  #if targetEnvironment(macCatalyst)
  /// 画笔工具依赖画布的第一响应者身份，关闭命令由画布自己处理，不抢走 PencilKit 焦点。
  var onCancel: (() -> Void)?
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(cancelEditing) { return onCancel != nil }
    return super.canPerformAction(action, withSender: sender)
  }
  override var keyCommands: [UIKeyCommand]? {
    let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelEditing))
    escape.wantsPriorityOverSystemBehavior = true
    return [escape] + (super.keyCommands ?? [])
  }
  @objc private func cancelEditing() { onCancel?() }
  #endif

  override init(frame: CGRect) {
    super.init(frame: frame)
    // 不让用户拖动画布、捏合缩放，缩放由布局决定。
    isScrollEnabled = false
    bounces = false
    bouncesZoom = false
    showsVerticalScrollIndicator = false
    showsHorizontalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    fitToBounds()
  }

  /// 按当前 bounds 设置缩放；不碰 drawing，撤销栈里的旧状态因此始终有效。
  func fitToBounds() {
    guard !fitting, logicalSize.width > 0, logicalSize.height > 0,
          bounds.width > 0, bounds.height > 0, fittedBounds != bounds.size else { return }
    fitting = true
    defer { fitting = false }
    let scale = bounds.width / logicalSize.width
    // 先放宽范围再设定值，避免新缩放落在旧的 [min, max] 之外被夹住。
    minimumZoomScale = min(minimumZoomScale, scale)
    maximumZoomScale = max(maximumZoomScale, scale)
    zoomScale = scale
    minimumZoomScale = scale
    maximumZoomScale = scale
    contentSize = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
    contentOffset = .zero
    fittedBounds = bounds.size
  }

  /// 原图尺寸合成：按固定逻辑矩形渲染笔迹，再铺满原图；结果与编辑时的窗口大小无关。
  func renderedImage(over image: UIImage) -> UIImage? {
    guard logicalSize.width > 0, image.size.width > 0 else { return nil }
    let logicalRect = CGRect(origin: .zero, size: logicalSize)
    let drawingImage = drawing.image(from: logicalRect, scale: image.size.width / logicalSize.width * image.scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
      drawingImage.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }

  static func logicalSize(for imageSize: CGSize) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let factor = logicalLongSide / max(imageSize.width, imageSize.height)
    return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
  }
}
