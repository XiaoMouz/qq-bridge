import SwiftUI

// Catalyst 的透明全屏覆盖不会可靠触发底层控制器 viewDidAppear。
// 在系统确认覆盖退出后通知工作区补布局；iOS 保持系统原有的呈现和关闭行为。
extension View {
  func platformFullScreenCover<Item: Identifiable, Cover: View>(
    item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Cover
  ) -> some View {
    modifier(ItemFullScreenCover(item: item, onDismiss: onDismiss, cover: content))
  }

  func platformFullScreenCover<Cover: View>(
    isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Cover
  ) -> some View {
    modifier(BooleanFullScreenCover(isPresented: isPresented, onDismiss: onDismiss, cover: content))
  }
}

private struct FullScreenDismissal: DynamicProperty {
  #if targetEnvironment(macCatalyst)
  @Environment(\.macFullScreenCoverDidDismiss) private var didDismiss
  #endif

  func notify() {
    #if targetEnvironment(macCatalyst)
    didDismiss()
    #endif
  }
}

private struct ItemFullScreenCover<Item: Identifiable, Cover: View>: ViewModifier {
  @Binding var item: Item?
  let onDismiss: (() -> Void)?
  let cover: (Item) -> Cover
  private var dismissal = FullScreenDismissal()

  func body(content: Content) -> some View {
    content.fullScreenCover(item: $item, onDismiss: {
      onDismiss?()
      dismissal.notify()
    }, content: cover)
  }
}

private struct BooleanFullScreenCover<Cover: View>: ViewModifier {
  @Binding var isPresented: Bool
  let onDismiss: (() -> Void)?
  let cover: () -> Cover
  private var dismissal = FullScreenDismissal()

  func body(content: Content) -> some View {
    content.fullScreenCover(isPresented: $isPresented, onDismiss: {
      onDismiss?()
      dismissal.notify()
    }, content: cover)
  }
}
