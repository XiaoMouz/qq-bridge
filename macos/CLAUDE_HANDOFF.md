# Claude Code → Codex 交接：Mac UI 分层重构（2026-10-14）

> 2026-10-15 更新：本文保留历史实现与验收记录。新建会话/编写/⌘N、侧栏更多菜单及 ⌘R 已按用户要求移除；手动同步仅在设置 → 同步。群助手返回现在固定于搜索框上方。当前行为以 SIDEBAR_NAVIGATION_UI_REVIEW.md 为准，不应恢复本文的旧入口。
执行：Claude Code（claude-opus-5-5）。范围：`macos/BetterChat/App` 的 Application / Navigation / DesignSystem / Features 展示层。**没有修改** `ios/`（共享展示层、Kit、协议）、后端，也没有修改 Codex 管理的 `Core/Services/MacAuthenticationService.swift`、`MacConversationService.swift`、`Features/Authentication/ViewModels/MacLoginViewModel.swift`、`Features/Conversations/ViewModels/MacDialogsViewModel.swift`。未提交、未改版本号、未运行 UI 自动化、未登录、未发消息。

## 结果概览

- 三个大文件已拆开并删除：`Application/MacWorkspaceController.swift`（376 行）、`Features/Conversations/MacConversationsController.swift`（473 行）、`Features/Conversations/MacSidebarSearch.swift`（313 行），另外删除了 `Application/MacSidebarControls.swift`。职责拆到下面的 coordinator、ViewModel、服务和纯展示组件里。改动前的源码快照在 `/tmp/betterchat-mvvm-baseline-20261014`（Codex 建的）。
- 构建：`xcodebuild -project macos/BetterChat/BetterChatMac.xcodeproj -scheme BetterChatMac -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath macos/.build-app build` 的结果是 **BUILD SUCCEEDED**，日志在 `/tmp/betterchat-claude-ui-build.log`。第一次构建因为 `UIBarButtonItem.toolTip` 在 Catalyst 上不存在而失败，删掉后第二次成功。`macos/BetterChat/App` 下的文件没有编译警告。
- 状态检查：`ChatOpenRequestCheck`（文件已移到新路径）、`ManualSyncCheck` 都已重新编译运行并通过。
- **没做的**：iOS 构建（这次没改共享源码；Codex 按计划会做）、截图、宽窄窗口实机、深浅色、键盘焦点、VoiceOver、Liquid Glass 的视觉效果。这些都**还没验证**，不能算通过。

## 文件清单（实际修改）

### Application（入口与装配）
| 文件 | 内容 |
|---|---|
| `MacApplication.swift`（重写） | AppDelegate 持有唯一的 `MacCommandRouter`；SceneDelegate 把 router 注入 `MacWindow` 和 `MacRootView`。不再用 `UIApplication.shared.delegate` 反查工作区控制器（只在 Scene 入口取一次 router）。 |
| `MacMenuBuilder.swift`（新） | 菜单栏「对话」「显示 → 页面」「设置…」，DEBUG 下的「布局检查」窗口尺寸；`MacWindow` 的快捷键（⌘F/⌘N/⇧⌘U/⌘R/⌘1–3/⌘,/⌃⌘S/Esc）。全部经 router 调用。 |
| `MacWorkspaceAssembly.swift`（新） | 依赖装配：Session → `MacSession*Service` → `MacDialogsViewModel` / `MacSidebarSearchViewModel` / `MacContactsViewModel` → `MacWorkspaceCoordinator`。登录页的装配（`MacLoginViewModel` 及其服务）也挪到这里，接口没变。`MacWorkspace` 这个 representable 用 SwiftUI Coordinator 持有工作区协调器，dismantle 时调 `tearDown()`。 |
| `MacRootView.swift`（重写） | 只负责按登录阶段切页面。全局浮层拆成 `MacGlobalOverlays` 修饰器，快速回复拆成 `MacQuickReplySheet` 修饰器（避免长修饰链拖慢类型推断，见 lessons「观察中」）；草稿交换走 `router.workspace`。 |
| `MacManualSync.swift` | 没动。 |

### Navigation（路由，状态的唯一所有者）
| 文件 | 内容 |
|---|---|
| `MacWorkspaceCoordinator.swift` | 实现 `MacWorkspaceCommands`。负责分区切换、右栏页面（聊天 / 联系人详情 / 设置页缓存）、⌘N 收件人选择、Esc 的退出顺序、重复点「消息」时滚到下一个未读、`AppModel.pendingChat` 和 `unreadBadge` 的观察（用 withObservationTracking 只读模型，UIKit 更新放在外面，onChange 用 weak self）、窗口标题。不做查询、不做过滤、不发 RPC。 |
| `MacAdaptiveSplitController.swift` | 保留原来的兼容策略：宽度 < 760 用单个 `UINavigationController`，否则用 `UISplitViewController`，两种布局搬移同一份 `sidebarRoot` / `detailRoot`。只写不读 `traitOverrides.horizontalSizeClass`。提供 `showSidebar` / `showDetail` / `toggleSidebar` / `revealSidebar`（⌘F 时先打开收起的侧栏）。 |
| `MacDetailContainer.swift` | 从原控制器里原样移出：右栏淡入切换，把子页导航栏投射到外层工具栏，系统 `backAction`。 |
| `MacHostingController.swift` | 原样移出。 |
| `MacChatCoordinator.swift` | 管当前聊天控制器、`MacChatDraft`（草稿、回到聊天的请求）、上次会话（经 `MacWorkspaceStore`）。同一会话重复打开不重建页面。 |
| `MacSidebarToolbar.swift` | 把侧栏的分区状态投射成 `UINavigationItem`。消息分区里「…」和「编写」放在同一个 `UIBarButtonItemGroup`。Codex 首轮实图显示系统仍把它们画成各自的圆形玻璃按钮，**没有共用背景**，这是系统的实际外观，不再去改。在群助手时左侧出现「返回消息」按钮。联系人分区放「刷新」（刷新中禁用），设置分区不放按钮。 |
| `MacPageFactory.swift` | 统一注入环境，创建聊天、设置、联系人详情、空状态和「新建消息」收件人选择（共享 `ChatPicker`）。 |
| `MacRoutes.swift` | `MacSidebarSection`（标题、符号、选中符号、搜索提示）、`MacSetting`（带搜索关键词）、`MacSidebarRoute`。 |
| `MacCommandRouter.swift` | `MacWorkspaceCommands` 协议，以及 weak 持有工作区的 router；登记变化时重建菜单。 |

### Core/Services（只新增，没改已有文件）
- `MacSearchService.swift`：读本地联系人、`searchMessages`、`openChat(with:)`、按需取头像。
- `MacContactsService.swift`：先给缓存快照，再 `listFriends` / `listGroups`（refresh 时先调 `refreshContacts`，和 iOS 一样）。
- `MacWorkspaceStore.swift`：读写 `mac.lastChat`（键名不变），查会话是否存在、会话标题。原来控制器里的 `UserDefaults` 和 `store.dialogItems` 调用挪到了这里。

### DesignSystem
- `MacMetrics.swift`：断点 760、窗口最小 440×480、侧栏 260/310/420、侧栏水平边距 12、搜索框高 32、tab 栏高 52、行头像 40（会话三行预览时 48）、间距 10、行边距、符号 17pt、过渡 0.18s；`dialogRow` 传给共享的会话行（第二轮接上）。`MacSymbol` 集中管理 SF Symbols。
- `Controls/MacSidebarSearchField.swift`（系统 `UISearchTextField`，有结果时按 Tab 进结果）、`Controls/MacFloatingTabBar.swift`（真实 `UITabBar`，泛型条目、选中时换 fill 图标、角标和未读的无障碍值）、`Controls/MacComposerMenu.swift`（名称不变，共享 ChatScreen 在用）。
- `Components/MacSidebarRow.swift`：搜索结果和联系人共用的行，加上 `macSidebarList()` 样式；`Components/MacEmptyState.swift`：空状态，以及 `MacStatusPill`（同步中的状态胶囊）。

### Features
| 目录 | ViewModel | View |
|---|---|---|
| Workspace | `MacSidebarViewModel`：分区、**每个分区各自的搜索词草稿**、未读数、设置和联系人的选中项、搜索框和结果的焦点请求、设置筛选（名称 + 关键词） | `MacSidebarView`：顶部搜索框 + 常驻的会话 / 联系人层 + 搜索结果替换 + 设置列表 + 底部悬浮 tab；减弱动态效果时不做动画 |
| Search | `MacSidebarSearchViewModel`：300ms 防抖，查询变了就取消旧任务，用代次隔离迟到的回包；联系人的打开继续用 `MacChatOpenRequest`（已移到 `Search/ViewModels/`）；结果是纯值，不再用 `AnyView`；会话来源复用 `MacDialogsViewModel.items`（加了只读的 `MacDialogSource` 扩展，没改它本身的文件），不另开数据库观察 | `MacSearchResultsController`（UIKit 差量更新，只重配内容变了的行；Tab / 上下 / Return / Shift-Tab）、`MacSidebarSearchView`（加载中、重试、无结果） |
| Contacts | `MacContactsViewModel`：缓存优先、刷新、删除后重载、分组展开、好友 / 群聊切换、筛选、头像 | `MacContactsSidebarView`：系统分段控件 + `List(selection:)`；重复选择不重建右栏 |
| Settings | 筛选放在 `MacSidebarViewModel` | `MacSettingsSidebarView`：`List(selection:)` + `Label`，图标不固定着色 |
| Conversations/Views | 用 Codex 的 `MacDialogsViewModel`（契约没变） | `MacDialogsController`（差量列表、群助手、右键菜单；会话改由 VM 的 `showsArchived` 驱动标题栏）、`MacChatPage` + `MacChatDraft` + `MacChatTitle`（名称不变，共享 ChatScreen 在用） |
| QuickReply/Views | — | `MacQuickReplyPage`（从 RootView 移出来，逻辑不变） |
| Downloads | 新增 `MacDownloadSettingsViewModel`，包一层 `MacDownloads.shared`，**授权和持久化逻辑没改** | `Views/MacDownloadSettingsView`（`formStyle(.grouped)`） |
| Authentication/Views | 用 Codex 的 VM | `MacLoginController` 只移了目录，内容没改 |

文档：`macos/DESIGN.md` 的「实现位置」改成新的分层；补了「每个分区的搜索词各自保留」和「联系人左栏改用 Mac 的 VM」。`macos/README.md` 里 `ChatOpenRequestCheck` 的源码路径已更新。

## 分层依赖

```text
MacAppDelegate ── MacCommandRouter ◀── MacWindow（快捷键）/ MacMenuBuilder / MacRootView（快速回复）
MacRootView ── MacWorkspace（representable）── MacWorkspaceAssembly
   └─ MacWorkspaceCoordinator（实现 MacWorkspaceCommands）
        ├─ MacAdaptiveSplitController ── MacSidebarHost(SwiftUI MacSidebarView) / MacDetailContainer
        ├─ MacChatCoordinator ── MacPageFactory、MacWorkspaceStore
        ├─ MacSidebarToolbar（UIKit 投射）
        ├─ MacSidebarViewModel / MacSidebarSearchViewModel / MacContactsViewModel / MacDialogsViewModel
        │     └─ MacSearchService / MacContactsService / MacConversationService（协议）
        │           └─ Session（QQBridgeKit）
        └─ AppModel（pendingChat、unreadBadge、quickReplyChat、openMessage：只在协调器和根视图里读写）
```

- ViewModel 里没有 UIViewController、UINavigationController、AnyView，也不调 `UIApplication.shared`；导航意图通过 `route` 闭包或返回值交给协调器。
- View 不发 RPC、不读 UserDefaults。头像获取从 View 的 `onAppear` 发出意图，由 VM 经服务调用 `AvatarBook`。
- 共享 iOS 页面（ChatScreen、UserProfileView、ContactGroupView、SettingsView、StorageView、PreferencesView、AboutView、ChatPicker）仍然在自己内部加载数据。这是 iOS 现有的业务实现，这次没去拆。

## 保留的功能入口（对照原来的实现）

- 三个分区、⌘1–3、⌘,、⌘F（侧栏收起时先打开）、⌘N 和工具栏的「编写」（都走同一个 `ChatPicker` 收件人选择；已有浮层时不再叠加）、⌘R 和「…→立即同步」、⇧⌘U、⌃⌘S 和菜单「显示/隐藏侧栏」、Esc（窄窗口详情 → 列表；有搜索词 → 清除；其他分区 → 回到消息）。
- 会话列表的右键菜单：快速回复、置顶、标为已读、免打扰、群助手进出；群助手汇总行和返回（新增了左侧返回按钮，菜单里的入口保留）。
- 重复点「消息」tab：先退出搜索或群助手，再滚到下一个未读，不打开会话、不清草稿。
- 搜索：会话、联系人、聊天记录三组结果；选中聊天记录后用 `openMessage` 定位；联系人没有会话时由服务端新建；重试、无结果、键盘导航。
- 联系人：好友分组 / 群聊、筛选、无结果、加载失败重试、刷新；右栏资料保留子页面（群文件等）；删除好友后重新加载列表并回到空详情。
- 设置：账号、偏好、下载、存储、关于；各页的控制器缓存在协调器里，切换分区后子页面还在。
- 聊天：草稿、回到聊天的请求、上次会话恢复（`mac.lastChat`）、通知 / 横幅 / 提示经 `pendingChat` 打开、快速回复的草稿双向移交和展开、通话浮层和横幅、QQ 掉线扫码、连接状态、同步失败的提示。

## 视觉调整（源码层面，**还没截图验证**）

- tab 图标改成 `message` / `person.2` / `gearshape`，选中时用 `.fill` 版本，由系统 UITabBar 负责玻璃效果和选中动画。
- 侧栏工具栏：「… / 编写」放进同一个 `UIBarButtonItemGroup`。实图（`/tmp/betterchat-ui-review/claude-round1-wide.png`）里仍然是系统画的独立圆形玻璃按钮，没有合并。
- 搜索框、分段控件、tab 栏用同一个水平边距 12；搜索结果和联系人行统一成头像 + 标题 + 副标题的间距；同步状态改用统一的胶囊。

## 需要 Codex 补的契约或检查

1. **iOS 构建**：这次没改共享源码，按约定仍需 Codex 跑一次确认。
2. **Computer Use 验收**（都没做）：440 / 600 / 1024 宽度下列表和详情的切换、侧栏收起与恢复、⌘N 选人后打开、tab 重复点击、联系人和设置在分区切换后保留、搜索 Tab 和上下键、深浅色、减弱动态效果、VoiceOver 读到的 tab 未读值。要特别看：群助手时左侧返回按钮的位置。（工具栏分组已由 Codex 实图确认是系统独立按钮，不再算问题。）
3. `MacDialogsViewModel` 现在通过 `MacDialogSource` 扩展给搜索提供 `items`。如果以后改了 `items` 的可见性或语义，请同步改 `Features/Search/ViewModels/MacSidebarSearchViewModel.swift` 顶部的协议。
4. 建议给新 VM 补无账号的状态检查（和 `macos/tests` 的写法一样）：`MacSidebarSearchViewModel`（快速换查询时旧回包被丢弃、联系人打开被新选择取代）、`MacContactsViewModel`（刷新期间 reload 的代次隔离）。它们依赖 QQBridgeKit 的类型，用 `swiftc` 单独编译需要带上 Kit，所以这次没写。
5. `ARCHITECTURE.md` 里「待 Claude Code 接手」那一节的第 1、2 条已有实际代码，第 3、4 条（视觉和截图验收）还没完成。这个文件归 Codex 维护，所以我没改，请按实际验收情况更新。
6. 共享 `ContactsView` 的侧栏参数（`sidebarQuery`、`onSelect` 等）Mac 已经不用了。为了不动 iOS 文件，暂时保留；需要清理时请连同 iOS 构建一起处理。

## 第二轮：按 Codex 审查修复（2026-10-14）

Codex 首轮构建和截图已确认：联系人搜索 → Something 群资料能走通（`claude-round1-wide.png`、`claude-round1-contact.png`）。这一轮处理审查提出的 6 条：

1. **迟到的联系人打开请求会抢走页面**：`MacSidebarSearchViewModel` 新增 `cancelPendingOpen()`，只给 `MacChatOpenRequest` 换代、清掉打开中的状态，**保留查询词、已有结果和选中项**。`MacWorkspaceCoordinator.select` 切到非消息分区时调用；`openChat`（会话列表、通知 / `pendingChat`、新建消息、搜索的路由）进来时也先调用。离开再回来时，早先的请求因为已经换代，迟到也不会再路由，不靠「路由时检查当前分区」。
2. **只有空格的查询**：`MacSidebarViewModel.isFiltering` 改用裁剪后的词，只有空格时继续显示会话列表，和搜索 VM 的 term 一致。另加 `hasQueryText`（原始文本非空），给 Esc 和重复点「消息」用，保证空格也能被 Esc 清掉。
3. **ViewModel 依赖 View 类型**：新增 `Features/Shared/MacPeerPresentation.swift`，包括 `MacPeerPresentation`（名称、搜索副标题、联系人副标题、匹配、去重键）和 `MacMessagePresentation.key`，都是纯函数，规则和 iOS 一致。搜索 VM 和联系人 VM 不再用 `SearchView.name`，也不再用定义在 iOS 视图文件里的 `searchKey` 扩展。`Format.preview` / `Format.listTime` 是共享的纯 enum（`DialogListView.swift`），不是视图类型，继续使用。
4. **初次窄布局进入空详情**：`MacAdaptiveSplitController` 新增 `hasDetail` 回调，切到窄布局时不再看 `split.isShowing(.secondary)`（宽布局下它总是 true）。改由协调器的 `currentSectionHasDetail` 回答：消息分区看有没有已选会话；联系人看有没有资料页；设置看用户是否实际点过选项，默认的「账号」只是占位，不算。另外，启动时静默恢复上次会话改为 `revealDetail: false`，窄窗口启动时停在列表，宽窗口右栏照常显示；通知、`pendingChat` 打开的会话仍会进入详情。手动搬移容器的策略没变，没用 Catalyst 的自动 collapse。
5. **`MacChatOpenRequest`**：加了 `deinit { task?.cancel() }`；`task` 和 `generation` 标成 `@ObservationIgnored`；原有的 generation 判断保留，`CancellationError` 仍然不上报成失败。`ChatOpenRequestCheck` 已重新编译运行，通过。
6. **头像和间距常量没真正接上**：在共享的 `ios/QQBridge/App/DialogListView.swift` 新增 `DialogRowStyle`（两行头像、三行头像、间距三个数）。默认值 48 / 56 / 12，和 iOS 原来的写死值完全一样；`DialogRow` 和 `ArchiveRow` 加了 `var style = DialogRowStyle.standard`，iOS 的调用方不用改。Mac 的 `MacDialogsController` 给会话行和群助手行都传 `MacMetrics.dialogRow`（40 / 48 / 10）。搜索结果去掉了单独的 36 点头像，统一成 40。DialogRow 的两行和三行预览、草稿、@ / 回复 / @全体前缀、免打扰图标、语音中标记、发送者显示、角标都没动。没有往共享类型里加任何 Mac 专属类，也没加 `#if`。

**没碰的文件**：Codex 新加的 `Core/Services/MacDownloadPreferences.swift`、`MacDownloads+Preferences.swift`、下载设置 VM 和 View（可注入的构造器）都原样保留。

**构建**：`xcodegen generate` 之后跑了一次 Mac Catalyst 构建，**BUILD SUCCEEDED**，日志在 `/tmp/betterchat-claude-ui-build.log`。新出现的警告只有 `DialogListView.swift` 里原有的 `Text +` 弃用警告，不是这次改的行。

**需要 Codex 做的**：
- 这一轮改了共享的 `DialogListView.swift`，**必须跑一次 iOS 构建**；外观应该和原来一模一样，最好截一张 iOS 会话列表核对。
- 实机验收（都没做）：
  - 搜索联系人后马上切到设置或联系人，之后不应被拉回消息；
  - 搜索框只输空格时会话列表还在，按 Esc 能清掉；
  - 1024 → 440 缩窄时，没有已选会话应停在列表，已选会话应留在聊天；
  - 窄窗口启动时停在列表；
  - Mac 会话行、群助手行的头像改成 40 点（三行预览时 48 点），并和联系人行左边对齐。
- 测试建议同上一轮第 4 条，可以加一条：`cancelPendingOpen` 之后，迟到的 opened 不会触发 `route`。

## 第三轮：搜索结果选中态对比度（2026-10-14）

起因：`claude-final-search-light.png` 中，选中行是系统蓝底，副标题和时间仍用 secondary，看不清。这一轮只改了两个文件：

- `DesignSystem/Components/MacSidebarRow.swift`：新增纯展示参数 `emphasized`（默认 false）。为 true 时，副标题和时间改用 `.primary` 层级，和标题一样；为 false 时仍是 `.secondary`。没有写死白色，非活动窗口、高对比度下的实际颜色交给系统决定。联系人行没有传这个参数，外观不变。
- `Features/Search/Views/MacSearchResultsController.swift`：cell 改用 `configurationUpdateHandler`，按 `state.isSelected` 生成 `UIHostingConfiguration`。选中变化时系统只更新这一行；内容变化仍由快照只重配变了的行。全局颜色和其他页面的选择行为都没动。

构建：Mac Catalyst（`macos/.build-app`）**BUILD SUCCEEDED**，日志在 `/tmp/betterchat-claude-search-contrast-build.log`，这两个文件没有警告。还没截图复查，需要 Codex 在浅色、深色和非活动窗口下各看一次选中行。
