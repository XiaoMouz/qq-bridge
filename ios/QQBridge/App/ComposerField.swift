// 聊天输入框（UITextView）：SwiftUI 的 TextField 做不到的两件事——
// 1. 实体键盘（含 iPhone 镜像、iPad 键盘）按回车发送，Shift / Option + 回车换行；屏幕键盘的回车照常换行。
//    拼音输入还在组字时，回车只把字母上屏，不发送。
// 2. 粘贴（⌘V、长按菜单）剪贴板里的图片、视频、文件时交给 onPasteMedia 做成附件；只有文字时照常粘贴文字。
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerField: UIViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  var placeholder = "消息"
  var maxLines = 6
  /// 实体键盘按了回车。
  var onSubmit: () -> Void
  /// 剪贴板里有媒体时调用；返回 true 表示已经处理（不再粘贴文字）。
  var onPasteMedia: () -> Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> ComposerTextView {
    let view = ComposerTextView()
    view.delegate = context.coordinator
    view.font = UIFont.preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .clear
    view.textColor = .label
    view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultHigh, for: .vertical)
    view.placeholder = placeholder
    view.text = text
    view.coordinator = context.coordinator
    return view
  }

  func updateUIView(_ view: ComposerTextView, context: Context) {
    context.coordinator.parent = self
    if view.text != text {
      view.text = text
      view.refreshPlaceholder()
      view.invalidateIntrinsicContentSize()
    }
    // 焦点：外面要求获得 / 失去时跟着变（放到下一轮，避免在更新视图的过程中改第一响应者）。
    if focused != view.isFirstResponder {
      let want = focused
      DispatchQueue.main.async {
        if want, view.window != nil, !view.isFirstResponder {
          view.becomeFirstResponder()
        } else if !want, view.isFirstResponder {
          view.resignFirstResponder()
        }
      }
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ComposerTextView, context: Context) -> CGSize? {
    let width = proposal.width ?? 240
    let fit = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let font = view.font ?? UIFont.preferredFont(forTextStyle: .body)
    let limit = font.lineHeight * CGFloat(maxLines) + view.textContainerInset.top + view.textContainerInset.bottom
    let scroll = fit > limit
    if view.isScrollEnabled != scroll {
      DispatchQueue.main.async { view.isScrollEnabled = scroll }
    }
    return CGSize(width: width, height: min(fit, limit))
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerField

    init(_ parent: ComposerField) { self.parent = parent }

    func textViewDidChange(_ view: UITextView) {
      parent.text = view.text
      (view as? ComposerTextView)?.refreshPlaceholder()
      view.invalidateIntrinsicContentSize()
    }

    func textViewDidBeginEditing(_ view: UITextView) {
      if !parent.focused { parent.focused = true }
    }

    func textViewDidEndEditing(_ view: UITextView) {
      if parent.focused { parent.focused = false }
    }
  }
}

final class ComposerTextView: UITextView {
  weak var coordinator: ComposerField.Coordinator?
  private let placeholderLabel = UILabel()

  var placeholder = "" {
    didSet { placeholderLabel.text = placeholder }
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
    placeholderLabel.adjustsFontForContentSizeCategory = true
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(placeholderLabel)
    NSLayoutConstraint.activate([
      placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func refreshPlaceholder() {
    placeholderLabel.isHidden = !text.isEmpty
  }

  // MARK: 实体键盘的回车

  override var keyCommands: [UIKeyCommand]? {
    let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed))
    send.wantsPriorityOverSystemBehavior = true
    let shiftNewline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newlinePressed))
    shiftNewline.wantsPriorityOverSystemBehavior = true
    let optionNewline = UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(newlinePressed))
    optionNewline.wantsPriorityOverSystemBehavior = true
    return [send, shiftNewline, optionNewline] + (super.keyCommands ?? [])
  }

  @objc private func returnPressed() {
    // 拼音还在组字：回车只把字母上屏（和系统输入法的习惯一样）。
    if markedTextRange != nil {
      unmarkText()
      return
    }
    coordinator?.parent.onSubmit()
  }

  @objc private func newlinePressed() {
    if markedTextRange != nil { unmarkText() }
    insertText("\n")
  }

  // MARK: 粘贴媒体

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), PasteboardMedia.available { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    if PasteboardMedia.available, coordinator?.parent.onPasteMedia() == true { return }
    super.paste(sender)
  }
}

/// 剪贴板里有没有能当附件发的东西（只看类型，不读内容，不会弹"允许粘贴"）。
enum PasteboardMedia {
  @MainActor static var available: Bool {
    let pb = UIPasteboard.general
    if pb.hasImages || pb.contains(pasteboardTypes: [MediaPasteboard.type]) { return true }
    // 文件（Mac 上在访达里复制的文件、视频、PDF 等）：有不是文字的类型，并且没有文字。
    guard !pb.hasStrings else { return false }
    return pb.types.contains { id in
      guard let type = UTType(id) else { return false }
      return !type.conforms(to: .text) && (type.conforms(to: .data) || type.conforms(to: .content))
    }
  }
}
