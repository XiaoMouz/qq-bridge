import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 下载：默认保存到系统 Downloads，可改选目录。
struct MacDownloadSettingsView: View {
  @State private var viewModel: MacDownloadSettingsViewModel
  @State private var choosingDirectory = false

  init(viewModel: MacDownloadSettingsViewModel = MacDownloadSettingsViewModel(downloads: MacDownloads.shared)) {
    _viewModel = State(initialValue: viewModel)
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("保存位置") {
          Text(viewModel.directoryPath).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
        Button("选择文件夹…", systemImage: "folder") { choosingDirectory = true }
        if !viewModel.usesDefaultDirectory {
          Button("恢复为 Downloads", systemImage: "arrow.uturn.backward") { viewModel.useDownloadsDirectory() }
        }
      } header: {
        Text("下载目录")
      } footer: {
        Text("聊天附件和群文件默认保存到系统 Downloads。更改目录只影响新的下载；同名文件会自动编号，不会覆盖已有文件。清理 App 缓存不会删除这些文件。")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("下载")
    .navigationBarTitleDisplayMode(.inline)
    .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { viewModel.choose($0) }
    .alert("无法设置下载目录", isPresented: Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.dismissError() } })) {
      Button("好") { viewModel.dismissError() }
    } message: { Text(viewModel.error ?? "") }
  }
}
