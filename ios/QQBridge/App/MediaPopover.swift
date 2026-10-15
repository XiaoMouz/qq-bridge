// 图片 / 视频的弹出式预览：聊天变暗、模糊，媒体以圆角卡片浮在中间。
// 关闭按钮在卡片外面（压在暗色背景上，白色图片也看得清，不挡视频控件）；点背景空白处、往下拖卡片都能关。
// 用全屏覆盖层实现但不要系统的上滑动画，进出场动画自己做（从中间放大淡入）。
import AVKit
import QQBridgeKit
import SwiftUI

#if targetEnvironment(macCatalyst)
/// 2026-10-14 实测：Catalyst 全屏媒体页需 UIKit 优先命令，Esc 和翻页共用同一响应者。
struct MacMediaKeyboard: UIViewControllerRepresentable {
  let close: () -> Void
  var previous: (() -> Void)? = nil
  var next: (() -> Void)? = nil
  /// 只有传入时才接管空格（播放 / 暂停）；其他媒体页不传，空格行为保持原样。
  var togglePlayback: (() -> Void)? = nil

  func makeUIViewController(context: Context) -> Controller { Controller(actions: self) }
  func updateUIViewController(_ controller: Controller, context: Context) { controller.actions = self }

  final class Controller: UIViewController {
    var actions: MacMediaKeyboard
    init(actions: MacMediaKeyboard) { self.actions = actions; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
      // 2026-10-15 实测：系统分享仍将 Esc 交给此响应者，必须先关闭分享而非媒体场景。
      // 其他弹层独占键盘；方向键和空格不能穿透到下面的图片或视频。
      if let presented = presentedViewController {
        guard presented is UIActivityViewController else { return [] }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeMedia))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
      }
      // 独立窗口全屏时让系统先处理 Esc 退出全屏，不直接销毁媒体窗口。
      var commands: [UIKeyCommand] = []
      if view.window?.windowScene?.isFullScreen != true {
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeMedia)))
      }
      if actions.previous != nil || actions.next != nil {
        // 到边界仍接住方向键，避免转交给底下的会话列表或其他控件。
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousImage)))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextImage)))
      }
      if actions.togglePlayback != nil {
        // 2026-10-15 实测：画廊视频页 SwiftUI VideoPlayer 不响应空格，由此键命令代为播放 / 暂停。
        commands.append(UIKeyCommand(input: " ", modifierFlags: [], action: #selector(togglePlayback)))
      }
      for command in commands { command.wantsPriorityOverSystemBehavior = true }
      return commands
    }
    @objc private func closeMedia() {
      if let share = presentedViewController as? UIActivityViewController {
        share.dismiss(animated: true) { [weak self] in
          guard let self, viewIfLoaded?.window != nil else { return }
          becomeFirstResponder()
        }
        return
      }
      guard presentedViewController == nil else { return }
      actions.close()
    }
    @objc private func previousImage() {
      guard presentedViewController == nil else { return }
      actions.previous?()
    }
    @objc private func nextImage() {
      guard presentedViewController == nil else { return }
      actions.next?()
    }
    @objc private func togglePlayback() {
      guard presentedViewController == nil else { return }
      actions.togglePlayback?()
    }
  }
}
#endif

extension View {
  /// iOS 使用透明媒体预览，Mac 交给独立窗口路由。
  func mediaViewer(item: Binding<MediaTarget?>, session: Session, chatId: Int64) -> some View {
    modifier(MediaViewerPresenter(item: item, session: session, chatId: chatId))
  }
}

private struct MediaViewerPresenter: ViewModifier {
  @Binding var item: MediaTarget?
  let session: Session
  let chatId: Int64
  #if !targetEnvironment(macCatalyst)
  @State private var shown: MediaTarget?
  #endif

  func body(content: Content) -> some View {
    #if targetEnvironment(macCatalyst)
    content.onChange(of: item, initial: true) { _, target in
      guard let target else { return }
      MacMediaWindows.shared.open(.message(target, session, chatId))
      item = nil
    }
    #else
    content
      .onChange(of: item) { _, new in
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { shown = new }
      }
      .platformFullScreenCover(item: $shown, onDismiss: { item = nil }) { target in
        MediaViewer(target: target, session: session, chatId: chatId)
          .presentationBackground(.clear)
      }
    #endif
  }
}

/// 弹出卡片的外壳：背景、关闭按钮、拖动关闭、进出场动画。content 按 aspect 的比例放进可用区域。
struct MediaPopover<Content: View, Accessory: View>: View {
  /// 媒体的宽高（不知道时按 4:3）。
  let aspect: CGSize?
  /// 卡片下面的东西（工具栏、提示）。
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let content: () -> Content
  @Environment(\.dismiss) private var dismiss
  @State private var visible = false
  @State private var drag: CGSize = .zero

  var body: some View {
    GeometryReader { geo in
      let card = cardSize(in: geo.size)
      ZStack {
        // 背景：模糊 + 压暗，点一下关闭。
        Rectangle()
          .fill(.ultraThinMaterial)
          .environment(\.colorScheme, .dark)
          .overlay(Color.black.opacity(0.55))
          .opacity(visible ? max(0.2, 1 - abs(drag.height) / 400) : 0)
          .ignoresSafeArea()
          .onTapGesture { close() }

        VStack(spacing: 16) {
          content()
            .frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .offset(drag)
            .scaleEffect(visible ? 1 - min(abs(drag.height), 300) / 1500 : 0.86)
            .gesture(dismissDrag)
          accessory()
            .opacity(visible && drag == .zero ? 1 : 0)
        }
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      // 关闭按钮：在卡片外，暗色玻璃 + 阴影，任何背景上都看得清。
      .overlay(alignment: .topTrailing) {
        Button { close() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.black.opacity(0.55)))
            .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: Circle())
            .shadow(color: .black.opacity(0.4), radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .padding(.trailing, 16)
        .padding(.top, 8)
        .opacity(visible ? 1 : 0)
      }
    }
    .onAppear { withAnimation(.spring(duration: 0.32, bounce: 0.18)) { visible = true } }
  }

  /// 往下（或往上）拖超过 120pt 就关，否则弹回去。
  private var dismissDrag: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { v in drag = CGSize(width: v.translation.width * 0.4, height: v.translation.height) }
      .onEnded { v in
        if abs(v.translation.height) > 120 || abs(v.predictedEndTranslation.height) > 300 {
          close()
        } else {
          withAnimation(.spring(duration: 0.3)) { drag = .zero }
        }
      }
  }

  private func close() {
    withAnimation(.easeIn(duration: 0.18)) { visible = false } completion: {
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) { dismiss() }
    }
  }

  /// 卡片尺寸：按比例放进屏幕，上面留关闭按钮、下面留工具栏的位置。
  private func cardSize(in size: CGSize) -> CGSize {
    let maxW = size.width - 24
    let maxH = max(200, size.height - 64 - 110)
    let a = aspect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? CGSize(width: 4, height: 3)
    let scale = min(maxW / a.width, maxH / a.height)
    return CGSize(width: a.width * scale, height: a.height * scale)
  }
}

// MARK: - 视频

/// 系统播放器（自带全屏、画中画、音量），放在卡片里。
struct InlineVideoPlayer: UIViewControllerRepresentable {
  let player: AVPlayer
  /// 往下拖视频：进度 0…1。
  var onDrag: (CGFloat) -> Void = { _ in }
  /// 拖够了松手：关闭。
  var onDismiss: (() -> Void)? = nil
  var playback: VideoPlayback = .shared

  func makeCoordinator() -> DragToDismiss { DragToDismiss() }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let vc = playback.controller(for: player)
    if onDismiss != nil {
      let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(DragToDismiss.pan(_:)))
      pan.delegate = context.coordinator
      vc.view.addGestureRecognizer(pan)
    }
    return vc
  }

  func updateUIViewController(_: AVPlayerViewController, context: Context) {
    context.coordinator.onDrag = onDrag
    context.coordinator.onDismiss = onDismiss
  }

  /// 往下拖关闭（和看大图一样）；只认明显往下的拖动，不影响播放器的进度条、音量。
  @MainActor final class DragToDismiss: NSObject, @MainActor UIGestureRecognizerDelegate {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDismiss: (() -> Void)?

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
      guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }
      let v = pan.velocity(in: view)
      return v.y > 0 && abs(v.y) > abs(v.x) * 1.5
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { false }

    @objc func pan(_ g: UIPanGestureRecognizer) {
      guard let view = g.view else { return }
      let t = g.translation(in: view)
      let progress = min(1, max(0, t.y / 300))
      switch g.state {
      case .changed:
        let scale = 1 - progress * 0.25
        view.transform = CGAffineTransform(translationX: t.x, y: max(0, t.y)).scaledBy(x: scale, y: scale)
        onDrag(progress)
      case .ended where t.y > 120 || g.velocity(in: view).y > 900:
        onDismiss?()
      default:
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { view.transform = .identity }
        onDrag(0)
      }
    }
  }
}

/// 正在放的视频：放在 App 级别，关掉预览后画中画里的视频还能接着放；退到后台自动转成画中画（有后台音频权限）。
@MainActor
final class VideoPlayback: NSObject, AVPlayerViewControllerDelegate {
  static let shared = VideoPlayback()
  private var current: AVPlayerViewController?
  #if targetEnvironment(macCatalyst)
  // 画中画属于具体控制器：内嵌切系统呈现、切视频后，旧代理回调不能改变新播放器。
  private weak var pictureInPictureController: AVPlayerViewController?
  #else
  private var inPictureInPicture = false
  #endif

  func controller(for player: AVPlayer) -> AVPlayerViewController {
    // 换了视频：之前的停掉（包括画中画里的）。
    if let current, current.player !== player {
      current.player?.pause()
      self.current = nil
      #if targetEnvironment(macCatalyst)
      pictureInPictureController = nil
      #endif
    }
    if let current { return current }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    let vc = AVPlayerViewController()
    vc.player = player
    vc.allowsPictureInPicturePlayback = true
    vc.canStartPictureInPictureAutomaticallyFromInline = true
    vc.entersFullScreenWhenPlaybackBegins = false
    #if targetEnvironment(macCatalyst)
    // Mac 的短视频播完后保留预览，用户仍可打开系统控件重播或定位。
    vc.exitsFullScreenWhenPlaybackEnds = false
    #else
    vc.exitsFullScreenWhenPlaybackEnds = true
    #endif
    vc.delegate = self
    current = vc
    return vc
  }

  #if targetEnvironment(macCatalyst)
  /// 内嵌控制器已有父节点，不能直接拿去 present；新呈现仍由同一管理器接收画中画事件。
  func fullScreenController(for player: AVPlayer) -> AVPlayerViewController {
    if current?.player === player {
      current = nil
      pictureInPictureController = nil
    }
    return controller(for: player)
  }
  #endif

  /// 关掉预览：没在画中画里就停掉。
  func previewClosed(_ player: AVPlayer?) {
    guard let player else { return }
    // 链接加载完成到 SwiftUI 挂载播放器之间也可能关闭，此时尚无 current 控制器。
    #if targetEnvironment(macCatalyst)
    if let current, current.player === player, pictureInPictureController === current { return }
    #else
    if current?.player === player, inPictureInPicture { return }
    #endif
    player.pause()
    if current?.player === player { current = nil }
  }

  nonisolated func playerViewControllerWillStartPictureInPicture(_ vc: AVPlayerViewController) {
    MainActor.assumeIsolated {
      #if targetEnvironment(macCatalyst)
      guard current === vc else { return }
      pictureInPictureController = vc
      #else
      inPictureInPicture = true
      #endif
    }
  }

  #if targetEnvironment(macCatalyst)
  nonisolated func playerViewController(_ vc: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) {
    // willStart 不代表启动成功；失败必须解除保留，已关闭的预览也要暂停并释放。
    playerViewControllerDidStopPictureInPicture(vc)
  }
  #endif

  nonisolated func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
    MainActor.assumeIsolated {
      #if targetEnvironment(macCatalyst)
      guard current === vc else { return }
      pictureInPictureController = nil
      #else
      inPictureInPicture = false
      #endif
      // 预览已经关了（画中画是独自留下的）：放完小窗就收掉。
      if vc.parent == nil, vc.view.window == nil {
        vc.player?.pause()
        if current === vc { current = nil }
      }
    }
  }

  nonisolated func playerViewController(
    _: AVPlayerViewController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
