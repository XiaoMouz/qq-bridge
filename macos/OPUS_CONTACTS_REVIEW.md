# Opus 联系人和资料入口复核（2026-10-15）

Claude Code Opus 5.5，auto 模式，只读评审；实机与构建由 Codex 执行。以下是评审时的源码结论，修复结果另见联系人恢复复验。

## 结论

按要求只读：没有编辑、构建、启动应用，也没有操作账号或读取秘密。共找到 3 项：两个确定的问题，一项已由工作区里的改动修复。账号设置没有找到有代码证据的确定问题。

**先说明一个前提**：工作区里已有未提交的 `MacContactGroupView`、`MacContactGroupViewModel`、`MacContactGroupService` 和 `MacContactGroupTests`，`macos/BetterChat/App/Navigation/MacPageFactory.swift:58` 也已经改走新视图。所以你提到的 ContactGroupView 打不开、等待不结束，在 Mac 上已经在修（应该是 Codex 那一路）。

### 1.（确定，最高优先级）删除好友的迟到回调会把用户之后打开的页面冲掉

- **证据**：
  - `ios/QQBridge/App/ProfileViews.swift:139` 用 `Task { await deleteFriend() }` 发起删除，这个任务不跟随页面，页面消失后它照样跑完。
  - 成功后 `:224` 无条件调用 `onDeleted?()`。
  - Mac 的回调在 `macos/BetterChat/App/Navigation/MacWorkspaceCoordinator.swift:253-258`：清空 `contactPage`、取消侧栏选中、刷新联系人列表，再调用 `select(.contacts)`。它不检查自己是不是还是当前页。
- **场景**：在好友 A 的资料里确认删除，网络慢。等待期间用户点开好友 B，或者切到「消息」去聊天。A 的删除回包到达后，B 的资料页被清掉，右栏变成空状态；如果用户在消息分区，还会被强行拉回联系人分区。这和上一轮修的 `MacChatOpenRequest` 是同一类问题，但出在删除这条路径上，没有被覆盖。
- **附带问题**：删除过程中按钮不变灰，可以确认两次，第二次请求可能报「操作失败」，尽管第一次已经删成功。
- **最小修复边界**：只改协调器里的这个闭包。
  - 闭包弱引用持有本次创建的 `page`。
  - `contacts.reload()` 总是执行，因为服务端确实已经删除。
  - 只有 `contactPage === page` 时才清空页面、取消选中；只有当前仍在联系人分区时才 `select(.contacts)`。
  - 不要取消删除任务：这是服务端写操作，取消客户端任务撤不回删除。
  - 可选：Mac 分支加一个「删除中」状态，期间禁用删除按钮。

### 2.（确定，已在修）ContactGroupView 打不开时无法重试，这是一个可行动作

- **Mac 上为什么更严重**：`MacWorkspaceCoordinator.swift:248` 的 guard 让再次点击同一个群变成无操作。iOS 可以返回再进入来重试，Mac 侧栏不行，只有先选别的联系人再选回来才能重来。
- **在修的版本我核对过**：
  - 用 `observeDialog(chatId:)` 等待会话落库，不受旧代码 5000 条上限影响。
  - 有 30 秒超时。
  - 用 generation 丢弃迟到的结果。
  - `onDisappear` 时取消，回来后重新加载。
  - 失败页有「重试」按钮。

  逻辑上没看出缺陷，4 项测试覆盖了重试、超时后迟到的成功和失败、离开后返回。**不需要重复建议**，待它提交后从真实入口验收即可。
- **剩余**：iOS 自己的 `ContactGroupView` 仍然在没有超时地等待，但这不属于 Mac 对齐的范围。

### 3.（确定，中等）群资料、群成员加载失败时静默显示为空，Mac 上没有恢复入口

- **证据**：
  - `ProfileViews.swift:366` 用 `try?` 吞掉群资料请求的错误。
  - `:367` 的 `GroupMembers.load`（`ios/QQBridge/App/ChatModels.swift:206`）失败时直接返回，界面显示「成员 0」，和真的没有成员分不开。
  - `GroupInfoView` 没有 `platformRefreshable`，再点同一个群又被上面那个 guard 挡住。
- **影响范围**：联系人打开的群资料（`MacContactGroupView` 只管拿到会话，成功后交给 `GroupInfoView`）和聊天标题打开的群资料（`ChatScreen.swift:343`）都受影响。
- **推测，未验证**：切到别的分区再回来，宿主控制器重新挂上时 `.task` 可能会重跑，等于有一条隐藏的恢复路径。没有实测过，不能当作可用的入口。
- **最小修复边界**：
  - `GroupMembers` 增加一个失败标记（或让 `load` 返回结果）。
  - `GroupInfoView` 只在 `#if targetEnvironment(macCatalyst)` 下加刷新按钮，重新拉群资料和 `members.load(refresh: true)`；成员区在失败时显示「加载失败 · 重试」一行。
  - iOS 行为不变。

### 账号设置：没有确定问题

- Mac 账号页复用 `SettingsView(accountOnly: true)`，`platformRefreshable` 在 Mac 上会提供工具栏刷新按钮，所以「连不上服务器」可以恢复。
- 推测项：扫码登录用的是 SwiftUI 内部的 `.sheet`。按 L6/L7，这只能算待验证的疑点，不能直接替换呈现方式。要等 QQ 掉线、从真实入口试过鼠标关闭再决定，而这个场景会动到在线状态，必须先征得你的同意。

退出登录、重新登录在 PARITY.md 里已列为待验收，这里不重复。
