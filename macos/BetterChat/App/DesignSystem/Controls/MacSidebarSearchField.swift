import SwiftUI
import UIKit

/// 使用系统搜索框，保留清除、焦点和辅助功能行为，而不是拼装文本框外观。
/// Tab 只在有结果时交给结果列表，没有结果时保持系统默认的焦点遍历。
struct MacSidebarSearchField: UIViewRepresentable {
  @Binding var text: String
  let prompt: String
  let focusRequest: UUID
  let hasResults: Bool
  var identifier = "mac.sidebar.search"
  var submit: (() -> Void)? = nil
  let focusResults: () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> SearchField {
    let field = SearchField()
    field.accessibilityIdentifier = identifier
    field.delegate = context.coordinator
    field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return field
  }
  func updateUIView(_ field: SearchField, context: Context) {
    context.coordinator.parent = self
    if field.text != text { field.text = text }
    field.placeholder = prompt
    field.accessibilityLabel = prompt
    field.focusResults = focusResults
    field.hasResults = hasResults
    field.returnKeyType = submit == nil ? .default : .search
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      DispatchQueue.main.async { if field.window != nil { field.becomeFirstResponder() } }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: SearchField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? MacMetrics.sidebarPreferredWidth, height: MacMetrics.searchFieldHeight)
  }
  @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
    var parent: MacSidebarSearchField
    var focusRequest: UUID
    init(_ parent: MacSidebarSearchField) { self.parent = parent; focusRequest = parent.focusRequest }
    @objc func changed(_ field: UISearchTextField) { parent.text = field.text ?? "" }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      parent.submit?()
      return true
    }
  }
  final class SearchField: UISearchTextField {
    var focusResults: (() -> Bool)?
    var hasResults = false
    override var keyCommands: [UIKeyCommand]? {
      guard hasResults else { return super.keyCommands }
      return [UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(nextResult))]
    }
    @objc private func nextResult() {
      _ = focusResults?()
    }
  }
}
