# Opus 5.5 草稿路由复核（2026-10-15）

Claude Code 使用 auto 权限模式，只读核对生产代码、测试日志及草稿恢复截图。真实界面由 Codex 操作。记录源：`/tmp/betterchat-opus-draft-route-final.jsonl`。截图为有限宽度输入框，完整文字恢复由操作前后辅助功能树的完整 Value 核对。

## 结论：没有阻塞问题

`MacChatCoordinator.swift` 这次的修改和我们商定的最小方案一致：

- **每个会话一个固定对象**：`drafts: [Int64: MacChatDraft]` 用 `draft(for:)` 懒创建，同一会话始终是同一个对象（`:19`、`:58-63`）。`open` 不再新建 `MacChatDraft`（`:30`、`:37-38`），切换会话时历史控制器照常重建，草稿留下。
- **关闭回调迟到也能写回**：`updateDraft` 不再检查当前会话（`:53-56`）。因为写的是固定对象的 `composer`，迟到的回调对正在显示的页面也会经 `ChatScreen` 的 `onChange(ObjectIdentifier)` 生效。
- **展开顺序无关**：`MacRootView.swift:114-125`、`MacQuickReplyPage.swift:17-23` 没改，两条写入路径传的仍是同一个 `@State composer`。测试 3 覆盖了两种顺序。
- **测试隔离**：`MacPageFactory: MacChatPageBuilding`（`MacPageFactory.swift:7`），协调器只依赖 `empty`/`chat` 两个方法，测试用替身就能构造。
- **测试结果**：日志里的命令是 `-only-testing:BetterChatMacTests/MacChatDraftTests`，5 项 `✔`，`** TEST SUCCEEDED **`。日志中的 `error` 只有 AXLoading 和 NSBundle 系统噪声，没有编译或断言失败。
- **截图**：右栏标题是「Something · 4 人」，输入框里有草稿文字，和「回 Something 后草稿恢复」一致。输入框左侧被裁掉了，截图本身证明不了文字完整，这一点以你的实测为准。

## 纠正上次报告

上次第 1 步写「快速回复起点必然为 nil」不适用于这次复现。这次起始主会话就是 Something，所以快速回复是从已有草稿复制的（`copyDraft`）。真正丢草稿的原因是：打开 BOT 时旧代码 `:30` 把 Something 的 `MacChatDraft` 换掉了；快速回复的关闭回调又被 `:48` 的当前会话检查挡掉，或者写进了已被换掉的旧对象。上次第 4 步提到过这种情况，但第 1 步的说法不对，以这里为准。

## 不阻塞的小问题

1. **注释过时**：`MacWorkspaceCoordinator.swift:6` 还写着「保存…当前聊天草稿」，现在草稿按会话保存在 `MacChatCoordinator` 里，可以顺手改一下。`MacChatPage.swift:4` 已经更新了。
2. **测试 5 的区分力较弱**：`pendingImportCompletesInOriginAfterQuickReplyRoute` 中，`copyDraft` 本来就共用 `attachmentQueue`，所以去掉 `updateDraft(quick, for: 1)` 这一步，会话 1 的附件断言照样能通过。路由写回的保证主要靠测试 2 和测试 3，所以不影响结论。
3. **快速回复状态未清**：资料卡的 pendingChat 路径仍然没有像 toast 路径（`MacRootView.swift:99`）那样清 `model.quickReplyChat`。你实测快速回复再次打开正常，没表现出问题，所以只作为一致性建议。
4. **草稿常驻内存**：草稿一直留到工作区释放，包括图片附件数据。这是你明确决定的取舍；测试 4 已验证工作区释放后 composer 会被回收。不加清理也就不会误删正在导入或带错误状态的草稿。
