import SwiftUI
import UIKit

/// 输入区“添加附件”：原生 UIButton + UIMenu，点按直接展开菜单（共享 ChatScreen 在 Catalyst 下使用）。
struct MacComposerMenu: UIViewRepresentable {
  let menu: UIMenu
  func makeCoordinator() -> Coordinator { Coordinator() }
  @MainActor final class Coordinator {
    var titles: [String]?
  }
  func makeUIView(context: Context) -> UIButton {
    var configuration = UIButton.Configuration.plain()
    configuration.image = UIImage(systemName: MacSymbol.attach)
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: MacMetrics.toolbarSymbolPointSize, weight: .medium)
    configuration.baseForegroundColor = .secondaryLabel
    configuration.contentInsets = .zero
    configuration.indicator = .none
    let button = UIButton(configuration: configuration)
    button.preferredBehavioralStyle = .pad
    button.showsMenuAsPrimaryAction = true
    button.accessibilityLabel = "添加附件"
    button.toolTip = "添加附件"
    return button
  }
  func updateUIView(_ button: UIButton, context: Context) {
    let titles = menu.children.map(\.title)
    // 重新设置 UIButton.menu 会重新计算按钮布局；不能在每次 SwiftUI 布局回调里赋值。
    guard context.coordinator.titles != titles else { return }
    context.coordinator.titles = titles
    button.menu = menu
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
    MacMetrics.composerButton
  }
}
