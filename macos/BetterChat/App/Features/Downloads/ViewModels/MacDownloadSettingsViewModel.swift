import Foundation
import Observation

/// 下载目录设置：页面只发意图，书签授权与持久化仍由 MacDownloads 负责（逻辑不变）。
@MainActor
@Observable
final class MacDownloadSettingsViewModel {
  private(set) var error: String?
  @ObservationIgnored private let downloads: any MacDownloadPreferences

  init(downloads: any MacDownloadPreferences) { self.downloads = downloads }

  var directoryPath: String { downloads.directoryPath }
  var usesDefaultDirectory: Bool { downloads.usesDefaultDirectory }

  func choose(_ result: Result<URL, any Error>) {
    error = nil
    do { try downloads.selectDirectory(result.get()) }
    catch { self.error = error.localizedDescription }
  }
  func useDownloadsDirectory() {
    error = nil
    downloads.useDownloadsDirectory()
  }
  func dismissError() { error = nil }
}
