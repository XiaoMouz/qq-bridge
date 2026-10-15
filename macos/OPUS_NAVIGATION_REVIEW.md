# BetterChat Mac 侧栏导航 / 会话内查找：Opus 只读评审（2026-10-15）

评审者：Claude Code（claude-opus-5-5），只读。没有构建、没有启动应用、没有操作 UI，也没有修改任何项目文件。
依据：根 AGENTS.md、docs/lessons.md、macos/SIDEBAR_NAVIGATION_UI_REVIEW.md、七个指定源文件，以及 MacWorkspaceCoordinator、MacCommandRouter、MacPageFactory、MacManualSync、MacRootView、ChatExtras/ProfileViews/ChatScreen 的 Mac 分支，外加六张截图。

## 结论

需求本身都已落实，没有发现功能性回归：

- 新建会话：`builder.remove(menu: .newItem)`；“对话”菜单只剩“搜索…”和“下一个未读会话”；`MacWindow.keyCommands` 里没有 ⌘N / ⌘R；`MacSidebarToolbar` 在消息分区下左右两侧都没有按钮组。sidebar-clean-final.png 与此一致。
- 立即同步：只在 `MacPageFactory .sync → MacSyncSettingsView` 里有入口，走 `router.workspace?.refreshDialogs()` 和同一个 `MacManualSync`。忙碌时按钮禁用；出错时由 `MacRootView` 的全局 alert 提示；完成后显示 toast。settings-sync-440.png 里内容完整。
- 群助手：从汇总行（`Row.archive`）进入；返回有三条路径：“‹ 消息”按钮、Esc（`cancelSidebarNavigation` 先退搜索再退群助手）、再点“消息”标签。两个页面分别按“最上方的行 + 行内偏移”保存位置，`finishPageTransition` 能收掉连续切换留下的旧过渡；系统开了减少动态效果时跳过动画。三张群助手截图里，返回按钮在深浅色、440 和宽窗口下都看得见，而且固定在搜索框上方。
- 会话内查找：群详情和私聊详情（`conversationID: chatId`）都进 `MacChatHistoryView`。搜索框是内容区自己的 UISearchTextField，回车或点按钮才查询。换代号加取消能挡住迟到的旧结果，`chatID` 过滤保证不显示别的会话的结果。chat-history-group-results.png 里布局和高亮正常。

下面三项是可以动手改的问题，按影响排序。不再报第四项。

## 1. 群助手翻页时没有裁剪，标题行也不在同一个过渡里（推测，要录屏确认）

- 位置：`MacDialogsController.swift:112-140`、`MacSidebarView.swift:27-47`
- 问题：
  - 进入时，新列表从 `+bounds.width` 处滑进来；返回时，旧页快照向 `+width` 滑出去。快照被加到 `collectionView.superview` 上，也就是 Representable 的包装视图。从这一层一直到 `MacSidebarView` 的 ZStack 都没有设 `clipsToBounds` 或 `.clipped()`。如果分栏的主列容器本身也不裁剪，宽窗口下这 0.24 秒里列表会画到右侧聊天区上面。
  - “‹ 消息 / 群助手”这一行是 SwiftUI 在下一次布局时才插入或移除的，而 `setArchived` 并不在 `withAnimation` 里调用，所以 `.transition(.opacity)` 实际上不起作用。快照的 frame 用的是旧高度，而列表在动画开始后会被 SwiftUI 压低或抬高 40pt，结果是快照和新页面垂直方向差 40pt，标题行也是直接跳出来的。
- 证据边界：截图只能证明结束后的状态。复验文档说“没有残影”，指的是结束状态，不能证明过渡过程中没有越界或跳动。
- 建议：在 1024 宽窗口下录屏，或用慢动画看一遍进入和返回。如果确认有问题，可以给 `container` 设 `clipsToBounds = true`（或者给侧栏的 ZStack 加 `.clipped()`）；标题行改成和列表用同一个动画驱动，或者干脆放进 UIKit 列表顶部的固定区域，让快照里也包含它。

## 2. 窄窗口里，标题栏在群助手页面仍然显示“消息”，三层标题重复

- 位置：`MacSidebarToolbar.swift:7-10, 28`；截图 sidebar-archive-440-light.png / -dark.png
- 问题：440 宽时，从上往下依次是窗口标题栏的“消息”、“‹ 消息”返回按钮、居中的“群助手”。`MacSidebarToolbar.State` 里只有 `section`，不包含 `showsArchived`，所以 `item.title` 在群助手页面也一直是“消息”。用户会看到“消息”出现两次，而且最上面的标题和当前页面不一致。宽窗口的标题栏不显示侧栏标题，所以没有这个问题。
- 建议：把 `showsArchived` 加进 State，进入群助手时标题栏显示“群助手”，或者在消息分区下清空标题；再看一遍 440 下深浅两种外观。

## 3. 交接文档和设计常量还留着已删掉的入口

- 位置：
  - `macos/CLAUDE_HANDOFF.md:18`：快捷键列表里还有 ⌘N、⌘R。
  - 同一文件 `:26`：写着“⌘N 收件人选择”。
  - 同一文件 `:32`：写着“新建消息收件人选择”。
  - 同一文件 `:81`：写着“工具栏的『编写』……⌘R 和『…→立即同步』”。
  - 同一文件 `:98`：写着“⌘N 选人后打开”。
  - `macos/REFACTOR_REVIEW.md:35`、`MEDIA_WINDOWS_UI_REVIEW.md:13`：仍把⌘N / “新建消息”当成现有功能。
  - `BetterChat/App/DesignSystem/MacMetrics.swift:57-58`：`MacSymbol.compose`、`MacSymbol.more` 已经没有任何地方引用。
- 影响：README 和 ARCHITECTURE 已经更新，但 CLAUDE_HANDOFF.md 是给下一个 agent 看的交接说明。照着它去验收或开发，会把删掉的入口当成回归“修回来”。
- 建议：把上面几处改成现在的行为，并在历史评审文件里注明“已于 2026-10-15 移除”；删掉这两个不再使用的常量。

## 没有认定为问题的地方

- Esc 是挂在窗口上的快捷键，焦点在输入框里时是否也会触发返回群助手：以前搜索和分区的 Esc 也是这样，这次没有改变它的行为，所以不算回归。
- 查询时如果旧结果还在，会在旧结果上面盖一层“正在查找…”：只是观感，不影响正确性。
- `senderName` 每一行都同步读一次本地库：结果条数少，暂时不会有性能问题。
