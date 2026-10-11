// 图片 / 视频的弹出式预览：聊天变暗、模糊，媒体以圆角卡片浮在中间。
// 关闭按钮在卡片外面（压在暗色背景上，白色图片也看得清，不挡视频控件）；点背景空白处、往下拖卡片都能关。
// 用全屏覆盖层实现但不要系统的上滑动画，进出场动画自己做（从中间放大淡入）。
import AVKit
import QQBridgeKit
import SwiftUI

extension View {
  /// 弹出媒体预览（替代 fullScreenCover：去掉系统的上滑动画，背景透明）。
  func mediaViewer(item: Binding<MediaTarget?>, session: Session, chatId: Int64) -> some View {
    modifier(MediaViewerPresenter(item: item, session: session, chatId: chatId))
  }
}

private struct MediaViewerPresenter: ViewModifier {
  @Binding var item: MediaTarget?
  let session: Session
  let chatId: Int64
  @State private var shown: MediaTarget?

  func body(content: Content) -> some View {
    content
      .onChange(of: item) { _, new in
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { shown = new }
      }
      .fullScreenCover(item: $shown, onDismiss: { item = nil }) { target in
        MediaViewer(target: target, session: session, chatId: chatId)
          .presentationBackground(.clear)
      }
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

  func makeUIViewController(context _: Context) -> AVPlayerViewController {
    VideoPlayback.shared.controller(for: player)
  }

  func updateUIViewController(_: AVPlayerViewController, context _: Context) {}
}

/// 正在放的视频：放在 App 级别，关掉预览后画中画里的视频还能接着放；退到后台自动转成画中画（有后台音频权限）。
@MainActor
final class VideoPlayback: NSObject, AVPlayerViewControllerDelegate {
  static let shared = VideoPlayback()
  private var current: AVPlayerViewController?
  private var inPictureInPicture = false

  func controller(for player: AVPlayer) -> AVPlayerViewController {
    // 换了视频：之前的停掉（包括画中画里的）。
    if let current, current.player !== player {
      current.player?.pause()
      self.current = nil
    }
    if let current { return current }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    let vc = AVPlayerViewController()
    vc.player = player
    vc.allowsPictureInPicturePlayback = true
    vc.canStartPictureInPictureAutomaticallyFromInline = true
    vc.entersFullScreenWhenPlaybackBegins = false
    vc.exitsFullScreenWhenPlaybackEnds = true
    vc.delegate = self
    current = vc
    return vc
  }

  /// 关掉预览：没在画中画里就停掉。
  func previewClosed(_ player: AVPlayer?) {
    guard let player, current?.player === player, !inPictureInPicture else { return }
    player.pause()
    current = nil
  }

  nonisolated func playerViewControllerWillStartPictureInPicture(_: AVPlayerViewController) {
    MainActor.assumeIsolated { inPictureInPicture = true }
  }

  nonisolated func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
    MainActor.assumeIsolated {
      inPictureInPicture = false
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
