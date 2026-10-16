import UIKit

/// 自动更新：加载 PlugIns/SparkleBridge.bundle（AppKit 写的 Sparkle 不能直接链进 Catalyst）。
/// Info.plist 里没配更新源（开发构建）时什么都不做，免得开发包去拉正式版。
@MainActor
enum MacUpdater {
  private static var bridge: NSObject?

  static var isAvailable: Bool { bridge != nil }

  static func start() {
    guard bridge == nil, !MacAppDelegate.runsStateTests,
      let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty,
      let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("SparkleBridge.bundle"),
      let bundle = Bundle(url: url), bundle.load(),
      let type = bundle.principalClass as? NSObject.Type
    else { return }
    bridge = type.init()
  }

  static func checkForUpdates() {
    _ = bridge?.perform(NSSelectorFromString("checkForUpdates"))
  }
}
