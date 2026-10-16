import Foundation
import SwiftUI
import UIKit

/// 菜单、窗口快捷键、根视图浮层都经由这里调用工作区，不再从 UIApplication 反查控制器。
@MainActor
protocol MacWorkspaceCommands: AnyObject {
  var isWorkspaceVisible: Bool { get }
  var canReturnToMessages: Bool { get }
  func presentationDidDismiss()
  func showMessages()
  func showContacts()
  func showSettings()
  /// 设置窗口的页面（按选项缓存，由工作区的页面工厂创建）。
  func settingsPage(_ setting: MacSetting) -> UIViewController
  func focusSidebarSearch()
  func toggleSidebar()
  func nextUnread()
  func refreshDialogs()
  func cancelSidebarNavigation()
  func openChat(_ id: Int64, composer: Composer?)
  func draftComposer(for id: Int64) -> Composer?
  func updateDraft(_ composer: Composer, for id: Int64)
  func requestWindowSize(width: CGFloat, height: CGFloat)
}

/// 应用入口创建的唯一路由；工作区出现时登记，退出登录或重建时注销。
@MainActor
final class MacCommandRouter {
  private(set) weak var workspace: (any MacWorkspaceCommands)?
  /// 工作区登记变化时重建菜单的可用状态。
  var workspaceChanged: (() -> Void)?

  func attach(_ workspace: any MacWorkspaceCommands) {
    guard self.workspace !== workspace else { return }
    self.workspace = workspace
    workspaceChanged?()
  }
  func detach(_ workspace: any MacWorkspaceCommands) {
    guard self.workspace === workspace else { return }
    self.workspace = nil
    workspaceChanged?()
  }
  var isAvailable: Bool { workspace?.isWorkspaceVisible == true }
}

// SwiftUI 覆盖页向当前工作区报告实际关闭，不从全局窗口反查控制器。
extension EnvironmentValues {
  @Entry var macFullScreenCoverDidDismiss: () -> Void = {}
}
