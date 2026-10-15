import Foundation

/// 下载目录偏好与页面状态分离，状态检查无需访问真实 Downloads 或安全作用域书签。
@MainActor
protocol MacDownloadPreferences {
  var directoryPath: String { get }
  var usesDefaultDirectory: Bool { get }
  func selectDirectory(_ url: URL) throws
  func useDownloadsDirectory()
}
