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

  /// 装在窗口的根视图上（2026-10-18 实机：直接装在 UIWindow 上收不到鼠标移动，锚点一直是 0,0）。
  static func install(on view: UIView) {
    let hover = UIHoverGestureRecognizer(target: Tracker.shared, action: #selector(Tracker.moved(_:)))
    hover.cancelsTouchesInView = false
    hover.delaysTouchesBegan = false
    hover.delaysTouchesEnded = false
    // 2026-10-17 实机：不让它和别的手势同时识别时，右键菜单弹不出来、聊天区停在一层模糊上。只观察，不参与竞争。
    hover.delegate = Tracker.shared
    view.addGestureRecognizer(hover)
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
      guard let window = hover.view?.window else { return }
      let point = hover.location(in: window)
      MacPointer.locations[ObjectIdentifier(window)] = point
      MacPointer.lastLocation = point
    }
  }
}

/// 在鼠标位置弹出 `content`（系统弹出框，点别处收起）；item 置 nil 时收起。
/// 2026-10-17 实机：自己用 UIKit 从窗口根控制器弹出时，Catalyst 把它画在主窗口里面、没有底和边框，
/// 标题还跑到窗口标题栏上；SwiftUI 的 .popover 是正常的系统弹出框。所以在鼠标位置放一个 1×1 的透明锚点，从它弹出。
/// 2026-10-18 实机：聊天页在嵌套的 UIHostingController 里，SwiftUI 的 .global 坐标和窗口坐标对不上，
/// 右键右下角的消息、弹出框却出在左上角。改用一个 UIKit 探针视图把窗口坐标换算到覆盖层自己的坐标，
/// 并且先放好锚点、下一轮再弹出（同一轮里弹出会先用旧位置）。
struct MacPointerPopover<Item: Identifiable, Popover: View>: ViewModifier {
  @Binding var item: Item?
  let size: CGSize
  /// 对着窗口里的这块区域弹出（例如右键的那条消息的气泡）；nil 时对着鼠标位置。
  /// 2026-10-18 实机：从右键菜单里点「转发」时鼠标已经在菜单项上，对着鼠标会盖住消息；
  /// 另外记右键位置的手势会搅乱系统右键菜单，所以由调用方直接给出消息的位置。
  var anchorRect: ((Item) -> CGRect?)? = nil
  @ViewBuilder let content: (Item) -> Popover
  /// 实际弹出的那一项：锚点放好后才设上。
  @State private var shown: Item?
  /// 锚点在覆盖层里的位置和大小。
  @State private var anchor = CGRect(x: 0, y: 0, width: 1, height: 1)
  @State private var probe = MacPointProbe.Holder()

  func body(content base: Content) -> some View {
    base
      // 探针放在后面：放在覆盖层里时，即使 allowsHitTesting(false)，UIKit 视图仍会挡住聊天里的点击
      // （2026-10-19 实机：点图片打不开查看器）。
      .background { MacPointProbe(holder: probe) }
      .overlay(alignment: .topLeading) {
        ZStack(alignment: .topLeading) {
          // 用 padding 定位而不是 offset：offset 只改画的位置，弹出框跟的是布局位置（2026-10-18 实机一直弹在左上角）；
          // .popover 要挂在 1×1 上、padding 在它外面，不然弹出框对着整块留白的边。
          Color.clear
            .frame(width: max(1, anchor.width), height: max(1, anchor.height))
            .popover(item: Binding(get: { shown }, set: { value in
              shown = value
              if value == nil { item = nil }
            })) { value in
              content(value)
                .frame(width: size.width, height: size.height)
                // 系统弹出框的玻璃底太透，后面的气泡图片会透到标题栏里。
                .presentationBackground(Color(uiColor: .systemBackground))
            }
            .padding(.leading, max(0, anchor.minX))
            .padding(.top, max(0, anchor.minY))
        }
        .allowsHitTesting(false)
      }
      .onChange(of: item.map { AnyHashable($0.id) }) { _, id in
        guard id != nil, let value = item else { shown = nil; return }
        let local = anchorRect?(value).flatMap { probe.local($0) } ?? probe.localPointer().map { CGRect(origin: $0, size: CGSize(width: 1, height: 1)) }
        anchor = local ?? anchor
        DispatchQueue.main.async { shown = value }
      }
  }
}

/// 覆盖层里的一个不可见 UIView：用它把鼠标的窗口坐标换算成覆盖层坐标。
struct MacPointProbe: UIViewRepresentable {
  @MainActor final class Holder {
    weak var view: UIView?
    func localPointer() -> CGPoint? {
      guard let view, let window = view.window, let point = MacPointer.location(in: window) else { return nil }
      return view.convert(point, from: window)
    }
    func local(_ windowRect: CGRect) -> CGRect? {
      guard let view, let window = view.window else { return nil }
      return view.convert(windowRect, from: window)
    }
  }
  let holder: Holder

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    holder.view = view
    return view
  }
  func updateUIView(_ view: UIView, context: Context) { holder.view = view }
}

extension View {
  func macPointerPopover<Item: Identifiable, Popover: View>(item: Binding<Item?>, size: CGSize, anchorRect: ((Item) -> CGRect?)? = nil,
                                                            @ViewBuilder content: @escaping (Item) -> Popover) -> some View {
    modifier(MacPointerPopover(item: item, size: size, anchorRect: anchorRect, content: content))
  }
}
#endif
