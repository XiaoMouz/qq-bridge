import Foundation
import Observation

/// 左栏的展示状态：当前分区、各分区独立的搜索词、联系人的选中项、焦点请求。
/// 分区切换只换左栏内容，各分区的搜索词作为草稿保留，切回来时仍在。
@MainActor
@Observable
final class MacSidebarViewModel {
  private(set) var section = MacSidebarSection.messages
  private var queries: [MacSidebarSection: String] = [:]
  private(set) var unread = 0
  private(set) var contact: ContactRoute?
  private(set) var isCompactLayout = false
  /// 递增即请求聚焦搜索框（⌘F、Shift-Tab 从结果返回）。
  private(set) var searchFocusRequest = UUID()
  /// 递增即请求把焦点交给消息搜索结果（搜索框里按 Tab）。
  private(set) var resultsFocusRequest = UUID()

  var query: String {
    get { queries[section] ?? "" }
    set { queries[section] = newValue }
  }
  func query(for section: MacSidebarSection) -> String { queries[section] ?? "" }
  /// 以裁剪后的词判断是否筛选：只有空格时仍显示原列表（搜索 ViewModel 也按裁剪后的词查询）。
  var isFiltering: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// 搜索框里是否有任何字符（含空格）；Esc 先清掉它再考虑切换分区。
  var hasQueryText: Bool { !query.isEmpty }

  func select(_ section: MacSidebarSection) { self.section = section }
  func clearQuery() { queries[section] = nil }
  func clearQuery(of section: MacSidebarSection) { queries[section] = nil }
  func setUnread(_ count: Int) { if unread != count { unread = count } }
  func setCompactLayout(_ compact: Bool) { isCompactLayout = compact }
  func select(_ contact: ContactRoute?) { self.contact = contact }
  func focusSearch() { searchFocusRequest = UUID() }
  func focusResults() { resultsFocusRequest = UUID() }
}
