import SwiftUI
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

  static var automaticallyChecks: Bool {
    get { (bridge?.value(forKey: "automaticallyChecksForUpdates") as? Bool) ?? false }
    set { bridge?.setValue(newValue, forKey: "automaticallyChecksForUpdates") }
  }

  static var lastCheckDate: Date? { bridge?.value(forKey: "lastUpdateCheckDate") as? Date }
}

/// 设置 → 关于里的「更新」：手动检查、自动检查开关、上次检查时间。
struct MacUpdateSection: View {
  // 出现时再从 Sparkle 读（默认值不能在主线程之外调 MacUpdater）。
  @State private var automatic = false
  @State private var lastCheck: Date?

  var body: some View {
    Section("更新") {
      if MacUpdater.isAvailable {
        Button("检查更新…") { MacUpdater.checkForUpdates() }
        Toggle("自动检查更新", isOn: $automatic)
          .onChange(of: automatic) { _, on in MacUpdater.automaticallyChecks = on }
        LabeledContent("上次检查", value: lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "还没有检查过")
      } else {
        // 开发构建没有更新源（见 release.sh 的 SPARKLE_FEED_URL）。
        Text("开发构建不检查更新").foregroundStyle(.secondary)
      }
    }
    .onAppear {
      automatic = MacUpdater.automaticallyChecks
      lastCheck = MacUpdater.lastCheckDate
    }
  }
}
