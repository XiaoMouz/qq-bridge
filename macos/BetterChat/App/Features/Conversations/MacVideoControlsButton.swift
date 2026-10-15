import AVKit
import SwiftUI

/// 2026-10-15 实机对照：Catalyst 内嵌 AVKit 不显示进度等控制项，直接呈现系统播放器则正常。
/// 继续使用同一 AVPlayer，避免切换呈现方式时重载资源、丢失进度。
struct MacVideoControlsButton: UIViewRepresentable {
  let player: AVPlayer
  var controllerProvider: ((AVPlayer) -> AVPlayerViewController)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(player: player, provider: controllerProvider) }

  func makeUIView(context: Context) -> UIButton {
    var configuration = UIButton.Configuration.glass()
    configuration.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
    configuration.cornerStyle = .capsule
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = "打开播放器"
    button.toolTip = "打开播放器：进度、倍速和画中画"
    button.addTarget(context.coordinator, action: #selector(Coordinator.open(_:)), for: .primaryActionTriggered)
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {
    context.coordinator.update(player: player, provider: controllerProvider)
  }

  static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
    coordinator.close()
  }

  @MainActor final class Coordinator: NSObject {
    private var player: AVPlayer
    private var provider: ((AVPlayer) -> AVPlayerViewController)?
    private weak var presented: AVPlayerViewController?

    init(player: AVPlayer, provider: ((AVPlayer) -> AVPlayerViewController)?) {
      self.player = player
      self.provider = provider
    }

    func update(player: AVPlayer, provider: ((AVPlayer) -> AVPlayerViewController)?) {
      self.provider = provider
      guard self.player !== player else { return }
      close()
      self.player = player
    }

    @objc func open(_ button: UIButton) {
      guard presented?.presentingViewController == nil else { return }
      // 从按钮所在的窗口与控制器出发，避免全局 keyWindow 选中另一个聊天窗口。
      var responder: UIResponder? = button
      while let current = responder, !(current is UIViewController) { responder = current.next }
      guard let presenter = responder as? UIViewController,
            presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
      let controller = provider?(player) ?? AVPlayerViewController()
      controller.player = player
      controller.showsPlaybackControls = true
      controller.exitsFullScreenWhenPlaybackEnds = false
      // 保留底层媒体页，避免 fullScreen 的 onDisappear 清理正在共用的 AVPlayer。
      controller.modalPresentationStyle = .overFullScreen
      presented = controller
      presenter.present(controller, animated: true)
    }

    func close() {
      // 媒体页被切换或移除时不留下上一页的系统播放器；播放状态由原页面的模型管理。
      presented?.dismiss(animated: false)
      presented = nil
    }
  }
}
