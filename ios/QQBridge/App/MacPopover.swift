// Mac：在鼠标所在位置弹出系统弹出框（回应面板、资料卡）。
// 2026-10-17 按 macOS 习惯改：以前这些都是窗口中间的模态表单（整窗变暗、不能操作别处）；
// Mac 上这类小面板应该贴着触发它的东西弹出，点别处就收起。
// 触发点（右键的气泡、点的头像）在聊天列表的格子里，SwiftUI 拿不到可靠的锚点，所以记住窗口里鼠标最后的位置作为锚点。
#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// 窗口里鼠标最后的位置（窗口坐标）。主窗口创建时装上。
@MainActor
enum MacPointer {
  private static var locations: [ObjectIdentifier: CGPoint] = [:]

  static func install(on window: UIWindow) {
    let hover = UIHoverGestureRecognizer(target: Tracker.shared, action: #selector(Tracker.moved(_:)))
    hover.cancelsTouchesInView = false
    hover.delaysTouchesBegan = false
    hover.delaysTouchesEnded = false
    // 2026-10-17 实机：不让它和别的手势同时识别时，右键菜单弹不出来、聊天区停在一层模糊上。只观察，不参与竞争。
    hover.delegate = Tracker.shared
    window.addGestureRecognizer(hover)
  }

  static func location(in window: UIWindow) -> CGPoint? { locations[ObjectIdentifier(window)] }
  /// 最后一次移动所在窗口里的位置。
  static private(set) var lastLocation: CGPoint?

  @MainActor final class Tracker: NSObject, UIGestureRecognizerDelegate {
    static let shared = Tracker()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    @objc func moved(_ hover: UIHoverGestureRecognizer) {
      guard let window = hover.view as? UIWindow else { return }
      let point = hover.location(in: window)
      MacPointer.locations[ObjectIdentifier(window)] = point
      MacPointer.lastLocation = point
    }
  }
}

/// 在鼠标位置弹出 `content`（系统弹出框，点别处收起）；item 置 nil 时收起。
/// 2026-10-17 实机：自己用 UIKit 从窗口根控制器弹出时，Catalyst 把它画在主窗口里面、没有底和边框，
/// 标题还跑到窗口标题栏上；SwiftUI 的 .popover 是正常的系统弹出框。所以在鼠标位置放一个 1×1 的透明锚点，从它弹出。
struct MacPointerPopover<Item: Identifiable, Popover: View>: ViewModifier {
  @Binding var item: Item?
  let size: CGSize
  @ViewBuilder let content: (Item) -> Popover
  /// 弹出时鼠标的位置（全局坐标）。
  @State private var anchor: CGPoint?

  func body(content base: Content) -> some View {
    base
      .overlay(alignment: .topLeading) {
        GeometryReader { geo in
          let origin = geo.frame(in: .global).origin
          // 弹出的那一次渲染里 onChange 还没记下位置：直接读鼠标当前位置；之后用记下的，鼠标再移动也不跟着跑。
          let point = item == nil ? nil : (anchor ?? MacPointer.lastLocation)
          let center = CGPoint(x: origin.x + geo.size.width / 2, y: origin.y + geo.size.height / 2)
          let p = point ?? center
          Color.clear
            .frame(width: 1, height: 1)
            .offset(x: p.x - origin.x, y: p.y - origin.y)
            .popover(item: $item) { value in
              content(value).frame(width: size.width, height: size.height)
            }
        }
        .allowsHitTesting(false)
      }
      .onChange(of: item.map { AnyHashable($0.id) }) { _, id in
        anchor = id == nil ? nil : MacPointer.lastLocation
      }
  }
}

extension View {
  func macPointerPopover<Item: Identifiable, Popover: View>(item: Binding<Item?>, size: CGSize,
                                                            @ViewBuilder content: @escaping (Item) -> Popover) -> some View {
    modifier(MacPointerPopover(item: item, size: size, content: content))
  }
}
#endif
