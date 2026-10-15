import SwiftUI

/// 桌面使用具名按钮，让鼠标、键盘与辅助功能共享同一个操作；手机保留点按手势。
struct MessageBlockAction: ViewModifier {
  let title: String
  var value = ""
  var enabled = true
  let action: () -> Void

  func body(content: Content) -> some View {
    #if targetEnvironment(macCatalyst)
    Button(action: action) { content }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .accessibilityLabel(title)
      .accessibilityValue(value)
      .help(title)
    #else
    content.onTapGesture(perform: action)
    #endif
  }
}
