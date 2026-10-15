import SwiftUI

/// 复用工作区的同步状态；切换设置页不会启动第二个任务或丢失错误提示。
struct MacSyncSettingsView: View {
  let sync: MacManualSync
  let synchronize: () -> Void

  var body: some View {
    Form {
      Section {
        HStack {
          Button("立即同步", systemImage: "arrow.triangle.2.circlepath", action: synchronize)
            .disabled(sync.isRunning)
          Spacer()
          if sync.isRunning {
            ProgressView().controlSize(.small)
            Text("正在同步…").foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("消息与会话")
      } footer: {
        Text("消息通常会自动更新。如果发现会话没有及时更新，可以手动同步。")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("同步")
    .navigationBarTitleDisplayMode(.inline)
  }
}
