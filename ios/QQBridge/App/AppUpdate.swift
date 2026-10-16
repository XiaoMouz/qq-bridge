// iOS 新版本提示：TestFlight 分发的 App 不能自己装更新，只安静地告诉你有新版、带你去 TestFlight。
// 版本信息由 iOS 发布流水线上传 TestFlight 后写到 R2：betterchat/ios/arm64/latest.json（地址在 Info.plist 的 BCUpdateInfoURL）。
// 不弹窗：「设置」标签上一个「新」字角标（进过一次「关于」就消失），设置页「关于」行和关于页里写明新版本。
// Mac 版走 Sparkle（MacUpdater.swift），这里不检查。
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AppUpdate {
  static let shared = AppUpdate()

  struct Info: Codable, Equatable {
    let version: String
    let build: Int
    var notes: String?
    var publishedAt: String?
  }

  private(set) var latest: Info?
  private(set) var lastCheck: Date?
  private(set) var checking = false
  private(set) var error: String?
  private var seenBuild: Int

  /// 回到前台时，距上次检查超过这么久才再查。
  private static let interval: TimeInterval = 6 * 3600
  private static let latestKey = "appUpdate.latest"
  private static let lastCheckKey = "appUpdate.lastCheck"
  private static let seenKey = "appUpdate.seenBuild"

  private init() {
    let defaults = UserDefaults.standard
    latest = defaults.data(forKey: Self.latestKey).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
    seenBuild = defaults.integer(forKey: Self.seenKey)
  }

  static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

  /// 比本机新的版本；没有就是 nil。
  var available: Info? {
    guard let latest, latest.build > Self.currentBuild else { return nil }
    return latest
  }

  /// 「设置」标签上的角标：有新版且还没在「关于」里看过。
  var showsBadge: Bool { (available?.build ?? 0) > seenBuild }

  func markSeen() {
    guard let available, available.build > seenBuild else { return }
    seenBuild = available.build
    UserDefaults.standard.set(seenBuild, forKey: Self.seenKey)
  }

  func checkIfDue() {
    #if !targetEnvironment(macCatalyst)
    if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
    Task { await check() }
    #endif
  }

  func check() async {
    var raw = Bundle.main.object(forInfoDictionaryKey: "BCUpdateInfoURL") as? String
    #if DEBUG
    // 调试：启动参数 -debugUpdateURL <地址> 换成本地的版本信息（模拟器里看提示效果，不碰线上的 R2）。
    if let debug = UserDefaults.standard.string(forKey: "debugUpdateURL") { raw = debug }
    #endif
    guard !checking, let raw, let url = URL(string: raw) else { return }
    checking = true
    defer { checking = false }
    do {
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
      request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
      let info = try JSONDecoder().decode(Info.self, from: data)
      latest = info
      error = nil
      lastCheck = Date()
      UserDefaults.standard.set(data, forKey: Self.latestKey)
      UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
    } catch {
      self.error = "检查失败，稍后再试"
    }
  }

  /// 打开 TestFlight（在里面点「更新」）。
  func openTestFlight() {
    let app = URL(string: "itms-beta://")!
    let web = URL(string: "https://testflight.apple.com")!
    Task {
      if await !UIApplication.shared.open(app) { await UIApplication.shared.open(web) }
    }
  }
}
