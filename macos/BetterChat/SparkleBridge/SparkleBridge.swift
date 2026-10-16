// Sparkle 是 AppKit 框架，Catalyst 的 App 不能直接链接：这个 macOS 插件包替它加载 Sparkle，
// App 运行时按类名找到 BCSparkleBridge，只调 checkForUpdates / canCheckForUpdates（见 MacUpdater.swift）。
// 更新源和公钥在 App 的 Info.plist（SUFeedURL、SUPublicEDKey）；沙盒下靠 SUEnableInstallerLauncherService
// 和 Sparkle.framework 里自带的 XPC 服务安装（Sparkle.framework 必须在 App 的 Contents/Frameworks，见 project.yml）。
import AppKit
import Sparkle

@objc(BCSparkleBridge)
public final class BCSparkleBridge: NSObject {
  private let controller: SPUStandardUpdaterController

  public override init() {
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    super.init()
  }

  @objc public func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  @objc public var canCheckForUpdates: Bool {
    controller.updater.canCheckForUpdates
  }

  /// 自动检查（启动时和每天一次）；Sparkle 自己存在用户偏好里。
  @objc public var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  @objc public var lastUpdateCheckDate: Date? {
    controller.updater.lastUpdateCheckDate
  }
}
