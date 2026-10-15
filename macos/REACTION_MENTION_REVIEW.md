# 回应与正文提及的桌面入口（2026-10-15）

本次落实 Opus 5.5 入口审计指出的两处长按依赖。Opus 因会话额度限制未参与这次实现，Codex 完成修改与真实 UI 验收。

## 修改

- Mac 回应胶囊使用标准 Button，辅助功能给出表情名称、人数和是否已回应；右键提供「查看回应者」。单击仍执行原加/取消回应动作。
- 名单内表情切换补名称及选中状态。正常入口实测发现点击成员后资料未立即出现，滚动聊天后才出现；Mac 现等名单的 `onDismiss` 回调再交付资料选择。
- Mac 正文 @ 徽章使用标准 Button；单击仍将提及加入输入草稿，右键可查看该人的资料。iOS 的点击/长按/振动保留原实现。

## 实际验收

在 Something 的既有消息上只读验证，不修改旧消息、不给它们加/取消回应：

1. 两种已有回应均可右键打开名单，标题与选择正确，人数仍为 1、我仍未回应。
2. 名单鼠标关闭后回到聊天；重新打开、切换表情、Esc 关闭通过。
3. 修复前，点击名单中的成员后只返回聊天，随后滚动才出现资料。最终构建中点击成员后直接出现资料表单，无需滚动或刷新；资料 Esc 返回聊天通过。
4. 正文提及右键打开对应资料，鼠标关闭通过；单击生成结构化提及草稿，确认后已清空，没有发送。
5. 已回到 Something 最新位置，输入框为空，供拖放诊断继续使用。

截图：`/tmp/betterchat-ui-review/reaction-users-mac.png`、`reaction-profile-handoff.png`、`mention-mac-draft.png`。第一个截图在补切换按钮辅助功能名称之前拍摄，外观未变化，最终名称及选中值另由实际 AX 树确认。

Mac 构建 `/tmp/betterchat-reaction-profile-build.log`、iOS 构建 `/tmp/betterchat-reaction-profile-ios-build.log` 均通过，Mac 严格签名与差异检查通过。此次未新增重复控件实现的测试；使用真实正常构建的入口与关闭/重开操作验证。未重新执行加/取消回应写操作，也未宣称完整 VoiceOver/键盘遍历验收。

## 后续：名单 MVVM 与失败恢复

Mac 名单改为 `MacReactionUsersPage`、`MacReactionUsersViewModel`、`MacReactionUsersService` 三层；iOS 继续使用原 `ReactionUsersSheet`。模型按表情缓存结果，刷新失败保留旧名单，空成功有「暂无回应者」，首次失败和刷新失败均复用已有状态组件提供重试。离开取消、旧响应隔离与请求防重由模型负责，资料跳转仍在名单实际关闭后交接。

`MacReactionUsersTests` 四项专项通过：`/tmp/betterchat-reaction-users-model-tests.log`。覆盖显式重试/空成功、跨表情迟到成功和失败、刷新保留/切回缓存、关闭重开与释放不被挂起请求保活。不连接真实账号，不把这些内存响应当作真实断网测试。

最终正常构建从同一真实右键入口验证：名单加载、点击刷新后名单保留、表情切换/标题/选择值、点击成员立即呈现资料、资料鼠标关闭、名单鼠标关闭、重开与 Esc 均通过。截图 `/tmp/betterchat-ui-review/reaction-users-refresh.png`。未改变任何回应或发送消息，已恢复 Something 最新位置和空输入。

最终 Mac `/tmp/betterchat-reaction-users-final-build.log`、iOS `/tmp/betterchat-reaction-users-ios-build.log` 构建通过，严格签名和差异检查通过；Package.resolved 未改动。此次失败恢复的证据是模型测试与已有状态组件，未中断真实网络制造名单错误。

设置关键词实际入口补验：正常构建在设置侧栏输入“扫码”，结果只保留“账号”；输入“通知”显示无匹配，不再误指向没有通知选项的“偏好”。随后清空查询，⌘1 恢复 Something 与空输入。没有点击退出或改变账号状态。
