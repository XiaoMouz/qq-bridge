// Mac 上的消息正文：照 iMessage 的做法用原生 UITextView，不用 SwiftUI 的 .textSelection——
// 2026-10-16 用户反馈 SwiftUI 版的三个问题：
// 1. 选中文字会连带选到末尾给时间留位的透明字（拷出来带着「17:33」）；
// 2. 选中时整段文字外面有一圈焦点框；
// 3. 右键气泡总是先进文字选区，很难弹出消息菜单。
// 2026-11-04 用户反馈：右键选中的文字弹系统文字菜单、别处弹消息菜单，一个气泡两种菜单很怪。
// 现在不能选文字（要拷贝用消息菜单的「复制」）：单击只给链接和 @ 徽章，右键一律交给气泡的消息菜单。
#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

struct MacMessageText: UIViewRepresentable {
  let runs: [Inline]
  let context: MessageContext
  let outgoing: Bool
  /// 末尾给发送时间留的位置（透明、不能被选中）。
  var reserve: String?

  static let mentionScheme = "qqbridge-mention"
  private static var font: UIFont { UIFont.preferredFont(forTextStyle: .body) }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MacMessageTextView {
    let view = MacMessageTextView()
    view.delegate = context.coordinator
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    // 选中时不画焦点框。
    view.focusEffect = nil
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: MacMessageTextView, context: Context) {
    context.coordinator.parent = self
    let (text, contentLength) = attributed()
    if view.attributedText != text {
      view.attributedText = text
      view.contentLength = contentLength
    }
    let tint = outgoing ? UIColor.white : UIColor.tintColor
    // 选区高亮用 tint：蓝色气泡里用白色，不然看不见。
    view.tintColor = tint
    // 下划线只给网址、号码（在正文里单独加）；@ 徽章也是链接，不能带下划线。
    view.linkTextAttributes = [.foregroundColor: tint]
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MacMessageTextView, context: Context) -> CGSize? {
    let width = proposal.width.map { max(1, $0) } ?? 10_000
    let rect = uiView.attributedText.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return CGSize(width: min(width, ceil(rect.width)), height: ceil(rect.height))
  }

  /// 正文 + 时间位；第二个值是正文长度（选区不能超过它）。
  private func attributed() -> (NSAttributedString, Int) {
    let font = Self.font
    let color = outgoing ? UIColor.white : UIColor.label
    let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let out = NSMutableAttributedString()
    for run in runs {
      switch run {
      case .text(let a):
        for piece in a.runs {
          var attrs = base
          // 只有「@全体成员」给了字体（加粗）。
          if piece.font != nil { attrs[.font] = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold) }
          if let link = piece.link {
            attrs[.link] = link
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
          }
          out.append(NSAttributedString(string: String(a[piece.range].characters), attributes: attrs))
        }
      case .face(let id, let name, let large):
        let size: CGFloat = large ? 64 : 20
        if let image = QQFace.image(id, size: size) {
          out.append(attachment(image, y: -4, attrs: base))
        } else {
          out.append(NSAttributedString(string: QQFace.text(id, name: name), attributes: base))
        }
      case .mention(let userId, let name, let avatar):
        let badge = MentionBadgeRenderer.render(name: name, avatar: avatar, outgoing: outgoing)
        let piece = NSMutableAttributedString(attributedString: attachment(badge.image, y: badge.baselineOffset, attrs: base))
        // 徽章当成链接：单击在输入框里 @ TA（见 Coordinator）。
        if let url = URL(string: "\(Self.mentionScheme)://\(userId)") {
          piece.addAttribute(.link, value: url, range: NSRange(location: 0, length: piece.length))
        }
        out.append(piece)
      }
    }
    let contentLength = out.length
    if let reserve {
      var attrs = base
      attrs[.font] = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
      attrs[.foregroundColor] = UIColor.clear
      out.append(NSAttributedString(string: "\u{2002}\u{2002}\(reserve)", attributes: attrs))
    }
    return (out, contentLength)
  }

  private func attachment(_ image: UIImage, y: CGFloat, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
    let a = NSTextAttachment(image: image)
    a.bounds = CGRect(x: 0, y: y, width: image.size.width, height: image.size.height)
    let s = NSMutableAttributedString(attachment: a)
    s.addAttributes(attrs, range: NSRange(location: 0, length: s.length))
    return s
  }

  /// SwiftUI 的末行基线：时间按它对齐（UIKit 视图默认没有，会落到底边）。
  static var lastBaselineFromBottom: CGFloat { -font.descender }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: MacMessageText?

    func textViewDidChangeSelection(_ view: UITextView) {
      // 不选文字：在链接上拖动等仍可能产生选区，立刻收掉。（isSelectable 要留着，否则链接点不了。）
      guard view.selectedRange.length > 0 else { return }
      view.selectedRange = NSRange(location: view.selectedRange.location, length: 0)
    }

    func textView(_ view: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
      guard let parent, case .link(let url) = textItem.content else { return defaultAction }
      if url.scheme == MacMessageText.mentionScheme, let id = Int64(url.host() ?? "") {
        return UIAction { _ in parent.context.actions.mention(id) }
      }
      if url.scheme == Linkify.numberScheme, let number = url.host() {
        return UIAction { _ in parent.context.actions.openNumber(number) }
      }
      return defaultAction
    }
  }
}

final class MacMessageTextView: UITextView {
  /// 正文长度（后面是时间位）。
  var contentLength = 0

  override var canBecomeFocused: Bool { false }

  /// 只有左键点在链接（含 @ 徽章）上才归文字；右键和别处都穿过去交给气泡（消息菜单、点按）。
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let hit = super.hitTest(point, with: event) else { return nil }
    if let event, event.buttonMask.contains(.secondary) { return nil }
    return linkAt(point) ? hit : nil
  }

  private func linkAt(_ point: CGPoint) -> Bool {
    guard let position = closestPosition(to: point),
      let range = tokenizer.rangeEnclosingPosition(position, with: .character, inDirection: .storage(.forward)) ?? textRange(from: position, to: position)
    else { return false }
    let index = offset(from: beginningOfDocument, to: range.start)
    guard index < attributedText.length, attributedText.attribute(.link, at: index, effectiveRange: nil) != nil else { return false }
    // closestPosition 在行尾空白处也会给最近的字符：再确认点确实落在那个字的框里。
    return firstRect(for: range).insetBy(dx: -2, dy: -2).contains(point)
  }
}
#endif
