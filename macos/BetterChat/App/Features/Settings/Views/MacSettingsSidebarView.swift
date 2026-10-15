import SwiftUI

/// 设置左栏：选项在左，内容在右。系统列表选择支持上下键切换并同步打开右栏。
/// 图标不固定着色，选中行跟随系统强调色时仍清晰可读。
struct MacSettingsSidebarView: View {
  let settings: [MacSetting]
  let query: String
  let selected: MacSetting
  let select: (MacSetting) -> Void

  var body: some View {
    List(selection: Binding<MacSetting?>(get: { selected }, set: { if let value = $0 { select(value) } })) {
      ForEach(settings, id: \.self) { setting in
        Label {
          Text(setting.rawValue)
        } icon: {
          Image(systemName: setting.symbol)
            .frame(width: MacMetrics.settingsIconWidth)
        }
        .listItemTint(.monochrome)
        .padding(.vertical, 4)
        .tag(setting)
      }
    }
    .macSidebarList()
    .overlay {
      if settings.isEmpty {
        ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespacesAndNewlines)).allowsHitTesting(false)
      }
    }
  }
}
