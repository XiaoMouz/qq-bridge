import Foundation
import Observation

@MainActor
@Observable
private final class DownloadPreferences: MacDownloadPreferences {
  var directoryPath = "/test/Downloads"
  var usesDefaultDirectory = true
  var rejectSelection = false
  func selectDirectory(_ url: URL) throws {
    if rejectSelection { throw CocoaError(.fileWriteNoPermission) }
    directoryPath = url.path
    usesDefaultDirectory = false
  }
  func useDownloadsDirectory() {
    directoryPath = "/test/Downloads"
    usesDefaultDirectory = true
  }
}

@main
struct DownloadSettingsCheck {
  @MainActor static func main() {
    let preferences = DownloadPreferences()
    let model = MacDownloadSettingsViewModel(downloads: preferences)
    let custom = URL(fileURLWithPath: "/test/Custom", isDirectory: true)
    preferences.rejectSelection = true
    model.choose(.success(custom))
    precondition(model.error != nil && model.usesDefaultDirectory && model.directoryPath == "/test/Downloads")
    preferences.rejectSelection = false
    model.choose(.success(custom))
    precondition(model.error == nil && !model.usesDefaultDirectory && model.directoryPath == custom.path)
    model.choose(.failure(CocoaError(.fileReadNoPermission)))
    precondition(model.error != nil && model.directoryPath == custom.path)
    model.dismissError()
    precondition(model.error == nil)
    model.useDownloadsDirectory()
    precondition(model.usesDefaultDirectory && model.directoryPath == "/test/Downloads")
    // 导出服务更新目录后，页面读取的仍是同一个来源，不缓存一份过时的路径。
    try! preferences.selectDirectory(custom)
    precondition(!model.usesDefaultDirectory && model.directoryPath == custom.path)
    print("下载设置检查通过：授权失败保留目录、成功重试、导入错误、恢复默认与单一状态来源")
  }
}
