# Opus 会话列表复核（2026-10-15）

Claude Code Opus 5.5，auto 模式，只读评审。以下为修复前源码结论，不代表实机复现；修复和验证另见 UNREAD_NAVIGATION_REVIEW.md。

已核对完服务层、命令路由和分栏控制器。结论如下（只读评审，没有改文件、构建或运行）。

# 会话列表操作与未读导航评审结论

**一致、没问题的部分**：
- **排序**：本地库按置顶在前、再按时间倒序返回（`Observations.swift:107`）。Mac 插入群助手汇总行的位置（`MacDialogsController.swift:199`）和 iOS 的分段写法结果相同，同一时间的会话也排在汇总行前面。群助手页内的排序两端也一样。
- **置顶 / 免打扰 / 群助手的策略值**：与 iOS 的 `DialogActions` 完全一致，包括私聊取消免打扰用 "default"、移出群助手回到 "muted"。
- **重复点「消息」标签的未读滚动**：只算普通列表里计入角标的未读，按显示顺序循环，和 iOS 的 `jumpToNextUnread` 一致。
- **重复点同一个操作**：在同步回来之前再点一次，发出的是相同的目标值，服务端结果不变。

## 问题

### 1. ⌘⇧U「下一个未读会话」在没有未读时仍会切换页面（中）
`MacWorkspaceCoordinator.swift:147-150` 先无条件执行 `showMessages()`，再去找未读。`showMessages()` 会清空消息搜索词、切回消息分区，并调用 `rootViewController.showSidebar()`；窄窗口下这会把当前聊天弹出导航栈（`MacAdaptiveSplitController.swift:102-104`）。

**触发步骤**：
1. 把窗口调到 760 点以下，打开一个聊天，并确保没有计入角标的未读。
2. 按 ⌘⇧U，聊天被关掉，回到会话列表，而且没有打开任何会话。
3. 换一种场景：在联系人或设置分区按 ⌘⇧U，会被切到消息分区；或者在消息搜索里按，搜索词会被清空。

有未读时，窄窗口还会先弹回列表再压入新聊天，出现一次多余的往返。

**最小修复**：先找到目标，找不到就什么都不做；也不需要先显示列表，因为 `openChat` 已经会做 `select(.messages, revealList: false)`。
```swift
func nextUnread() {
  guard let next = dialogsViewModel.nextUnread() else { return }
  sidebar.clearQuery(of: .messages)
  openChat(next.id, title: next.title, composer: nil)
}
```

### 2. 连续失败时，后一个错误被吞掉（低–中）
`MacDialogsController.swift:76-86` 只在观察到的状态变化、并且当前没有弹窗时才显示错误。`perform` 每次失败都直接覆盖同一个 `error`（`MacDialogsViewModel.swift:97`），而点「好」会无条件把它清空。

**触发步骤**：
1. 在后端不可达时，右键会话 A 选「置顶」，再立刻右键会话 B 选「免打扰」。
2. A 的错误弹窗出现后，B 的错误覆盖了 `error`。这时已经有弹窗，所以不会再弹。
3. 点「好」之后 `error` 被清空，B 的失败没有任何提示。用户也看不出是哪个会话、哪个操作失败了。

**最小修复**：把 `error` 改成一个队列，每条带上操作名和会话名（例如「置顶 xxx 失败」）。`dismissError` 只移除当前这一条，关闭弹窗后如果还有剩余就接着弹。

### 3. 右键「标为已读」没有按未读状态隐藏（低，和 iOS 不一致）
`MacDialogsController.swift:248` 对所有会话都显示这一项；iOS 的右键菜单和左滑都只在 `unreadCount > 0` 时显示（`DialogListView.swift:124,146`）。对已读会话点它会发出一次无效的 markRead 请求。

**最小修复**：按 iOS 的条件，`item.dialog.unreadCount > 0` 时才加这一项。

### 4. 本地库观察出错后，列表不再更新，也没有恢复路径（低）
`MacDialogsViewModel.swift:42-46` 出错时把 `observation` 置空并写入 `error`。但 `start` 只在 `viewDidLoad` 里调用一次，之后没有任何地方重启。

**结果**：会话列表和角标会停在出错时的状态，而错误弹窗用的标题是「操作未完成」，看起来像是某个右键操作失败了。iOS 是直接静默停止，所以 Mac 至少还有提示。

**最小修复**：在 ViewModel 里保存 `updated` 回调；`dismissError` 时（或者在弹窗里加一个「重试」按钮）如果 `observation == nil` 就重新 `start`。观察失败使用单独的文案。

### 5. 同一会话的两次策略修改是并发发出的，最终结果不确定（低，iOS 也一样）
`perform` 每次都单独开一个 Task（`MacDialogsViewModel.swift:91-98`），对同一个会话没有排队。

**触发步骤**：对一个群先点「免打扰」，在同步回来之前马上再点「收进群助手」。两个 `setNotifyPolicy` 请求同时发出，到达服务端的顺序没有保证，群最后可能停在 "muted" 而不是 "archived"。

**最小修复**：按 chatID 串行执行，后一个操作 `await` 前一个任务完成后再发。

## 两端相同的取舍（不算差异，供参考）
群助手里的群如果有 @我 或回复我，会计入「消息」标签的角标（`badgeCount` 对 archived 只算 @我 和回复我）。但 ⌘⇧U 和重复点标签都会排除群助手里的会话（`MacDialogsViewModel.swift:59,68`；iOS 的 `DialogListView.swift:85` 也有注释说明不算）。结果是角标显示有未读，键盘却跳不到。如果想处理，可以在普通列表里找不到未读时回退到 `setArchived(true)`，再定位到对应的群。

## 没有报告的疑点
错误弹窗是从嵌在 SwiftUI 里的子控制器弹出的。窄窗口显示聊天时它能不能正常出现，我只能从源码推测，按 L6 不能当作缺陷。如果需要，从真实入口复现一次就能确认。
