import SwiftUI
import UIKit

/// 2026-10-14 实测：从页面内部呈现时，资料卡工具栏落到后方主窗口；
/// 从窗口根控制器呈现独立 regular 表单后，卡片的鼠标关闭与 Esc 均恢复。
/// 选择仍由原页面持有；关闭、Esc、系统取消统一清除该选择。
struct MacFormPresenter<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
  @Binding var item: Item?
  let content: (Item) -> Content
  @Environment(AppModel.self) private var model
  @Environment(\.session) private var session

  func makeUIViewController(context: Context) -> MacFormAnchor<Item.ID> { MacFormAnchor<Item.ID>() }
  func updateUIViewController(_ controller: MacFormAnchor<Item.ID>, context: Context) {
    let selection = $item
    controller.update(id: item?.id, content: item.map {
      AnyView(content($0).environment(model).environment(\.session, session))
    }, close: { selection.wrappedValue = nil })
  }
  static func dismantleUIViewController(_ controller: MacFormAnchor<Item.ID>, coordinator: ()) {
    controller.tearDown()
  }
}

@MainActor
final class MacFormAnchor<ID: Hashable>: UIViewController, UIAdaptivePresentationControllerDelegate {
  private var requestedID: ID?
  private var shownID: ID?
  private var card: MacFormHost?
  private var content: AnyView?
  private var close: (() -> Void)?
  private var updateTask: Task<Void, Never>?
  private var isTornDown = false

  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    scheduleUpdate()
  }

  func update(id: ID?, content: AnyView?, close: @escaping () -> Void) {
    guard !isTornDown else { return }
    requestedID = id
    self.content = content
    self.close = close
    scheduleUpdate()
  }

  private func scheduleUpdate() {
    guard !isTornDown else { return }
    updateTask?.cancel()
    // 呈现不在 representable 更新中同步执行；任务读当前选择，取消后不会再弹出旧卡片。
    updateTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self, !isTornDown, viewIfLoaded?.window != nil else { return }
      if let card {
        guard shownID != requestedID else { return }
        self.card = nil
        shownID = nil
        card.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in self?.scheduleUpdate() }
        return
      }
      guard let requestedID, let content,
            let presenter = view.window?.rootViewController,
            presenter.presentedViewController == nil else { return }
      let card = MacFormHost(rootView: content)
      card.onClose = { [weak self] in self?.close?() }
      card.onDismiss = { [weak self, weak card] in
        guard let self, let card, self.card === card else { return }
        self.card = nil
        shownID = nil
        close?()
      }
      card.modalPresentationStyle = .formSheet
      card.preferredContentSize = CGSize(width: 400, height: 440)
      card.traitOverrides.horizontalSizeClass = .regular
      card.presentationController?.delegate = self
      self.card = card
      shownID = requestedID
      presenter.present(card, animated: !UIAccessibility.isReduceMotionEnabled)
    }
  }

  func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
    .none
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard presentationController.presentedViewController === card else { return }
    card = nil
    shownID = nil
    close?()
  }

  func tearDown() {
    // 2026-10-14 UIKit 转场测试复现：dismiss 的 completion 会晚于 dismantle，不能再安排呈现。
    isTornDown = true
    updateTask?.cancel()
    updateTask = nil
    requestedID = nil
    shownID = nil
    content = nil
    close = nil
    card?.dismiss(animated: false)
    card = nil
  }
}

private final class MacFormHost: UIHostingController<AnyView> {
  var onClose: (() -> Void)?
  var onDismiss: (() -> Void)?
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // 外部路由主动 dismiss 不会触发 adaptive delegate，也必须清掉原页面的选择。
    if presentingViewController == nil { onDismiss?() }
  }
  override var keyCommands: [UIKeyCommand]? {
    let cancel = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeCard))
    cancel.wantsPriorityOverSystemBehavior = true
    return (super.keyCommands ?? []) + [cancel]
  }
  @objc private func closeCard() { onClose?() }
}
