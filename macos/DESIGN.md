# Mac 界面与页面导航

2026-10-14：按用户修订的 Telegram 路由职责与 iMessage 视觉要求重做。本文替代此前“窗口顶部四个标签”的方案。

## 页面职责

宽窗口使用双栏工作区；窄窗口按列表 → 详情导航，同一时刻只呈现一栏。左栏负责选择与搜索，右栏承载实际内容。左栏底部只有消息、联系人、设置三个系统 `UITabBar` 标签，使用系统 Liquid Glass 外观；搜索不再作为顶层标签。

| 左栏分区 | 左栏内容 | 右栏内容 |
|---|---|---|
| 消息 | 会话列表、群助手；输入搜索后由结果替代列表 | 当前聊天；选择搜索消息后定位并高亮原消息 |
| 联系人 | 好友分组 / 群聊列表，顶部搜索筛选 | 选中好友或群的详细资料；“发消息”回到消息分区 |
| 设置 | 账号、偏好、下载、存储、关于；顶部可筛选选项 | 当前选项对应页面及其子页面 |

聊天标题右侧的信息按钮打开会话资料。通知策略、成员、聊天记录查找、共享媒体、公告、精华、群文件、相册继续由资料页面进入，返回按钮回到聊天。普通联系人资料与群资料复用 iOS 的业务功能。

搜索框固定在左栏顶部，每个分区的搜索词各自保留（切换分区再回来仍在）。消息分区内按名字、备注、号码即时匹配会话与联系人，并在停止输入 300 毫秒后查询服务端聊天记录；加载、失败重试和无结果都留在左栏。查询改变时取消旧任务，旧结果不能覆盖新词。点击结果保留左栏结果以便继续查阅；清除或 Esc 恢复会话列表。

## 状态与视觉

- 按窗口可用宽度切换容器：760 点以下使用单个 `UINavigationController` 紧凑导航，列表选择后进入详情，返回恢复原列表；宽窗口使用 `UISplitViewController` 双栏；两种布局搬移同一份页面控制器，避免 Catalyst 自动折叠 Mac 工具栏的无效宽度问题。左栏默认 310、范围 260–420，窗口最小 440 × 480。使用系统侧栏按钮及 ⌃⌘S 收起/恢复；⌘F 在隐藏侧栏时先打开侧栏。
- 差量会话列表继续使用 UICollectionView；联系人分组状态、当前聊天控制器、设置详情控制器在分区切换时保留，聊天输入不会因切换分区而重建。
- 左栏采用系统侧栏材质、清晰的圆形头像与选中状态；搜索、分区标题、底部导航始终在同一栏内。右侧聊天沿用蓝色气泡与克制的标题栏，右侧设置使用系统表单。
- 玻璃集中用于底部浮动导航及系统工具栏，信息内容不叠加装饰玻璃。颜色跟随系统明暗及无障碍设置。
- 消息按钮显示未读提示，并提供未读数的无障碍描述；三个分区都提供选中语义。
- 联系人条目显示当前选中状态，重复选择保留右侧已有子页面；切换分区后仍保留资料与选择。联系人和设置搜索无匹配时在左栏给出无结果提示，不清空右侧详情。

快速回复从当前同一会话复制完整草稿，浮层独立编辑；关闭时交回当前会话，展开时随导航移交文字、提及、回复和待发送附件。主页面和浮层不同时共享输入弹窗状态，避免一次输入触发两份提及选择器。此处为进程内状态保留，不提供跨重启草稿存储。

## 键盘

⌘1 消息、⌘2 联系人、⌘3 设置，⌘, 也打开设置。⌘F 聚焦当前分区的侧栏搜索，⇧⌘U 跳到下一个未读会话。“对话 → 搜索”同样聚焦侧栏。手动同步只保留在设置中，移除 ⌘N / ⌘R 和新建消息流程。Esc 优先由媒体或当前弹窗处理；根工作区先清除当前分区的搜索，保留右侧详情，紧凑详情页先返回列表，没有搜索且位于列表时才返回消息。

账号、下载及其他设置详情统一使用工具栏内标题，避免把手机的大标题层级带入桌面双栏。搜索框按分区显示搜索范围；“显示 → 页面”只列出消息、联系人、设置，搜索不作为第四个页面。

已选中消息分区时再次点击底部“消息”：有搜索或正处于群助手时先回普通列表；否则只将侧栏滚到下一个计入角标的未读会话，到尾部循环。右侧聊天、草稿及已读状态不因侧栏定位而改变。菜单与 ⇧⌘U 仍执行打开下一个未读会话。

联系人和设置使用系统列表选择。Tab 从搜索框进入列表，方向键在可选条目之间移动时同步打开右侧内容；鼠标也使用同一选择状态。选中行颜色跟随系统焦点，设置图标不固定着色，以保证选中时可读。采用 [SwiftUI List 的 selection 接口](https://developer.apple.com/documentation/swiftui/list)，不再只用按钮模拟行选择。

消息搜索结果使用 UIKit 差量侧栏列表。从搜索框按 Tab 进入结果，上下键选择并打开右侧内容，Return 重新定位当前结果，Shift-Tab 返回搜索框。查询变化清除旧选择；没有结果时不接管 Tab。鼠标重复点击当前结果仍能从资料页面返回聊天。

## 原生控件与对齐（第二轮截图修订）

- 主、次栏分别使用 Mac 行为的 `UINavigationController`，窗口使用 unified 工具栏。顶部只保留一行系统工具栏，避免窗口标题与 iPad 导航栏叠出两层。
- SwiftUI 子页面继续管理导航路径；将公开的 `UINavigationItem` 标题、按钮组和返回动作投射到外层工具栏；Catalyst 原生栏不显示独立副标题，聊天人数和输入状态合并到单行标题。返回使用系统 `backAction`，位于右栏标题左侧，资料入口位于标题右侧。
- 侧栏搜索使用 `UISearchTextField`；联系人类型使用系统分段选择器。底部使用真实 `UITabBar`，由系统管理选中动画、符号布局和辅助功能标签语义。
- 分区内容使用 0.18 秒淡入淡出，右栏切页只保留不可交互的过渡快照；开启“减弱动态效果”时取消该动画。
- 输入区附件、表情、麦克风统一 17 点 medium 符号。附件是原生 `UIButton` + `UIMenu`，表情是无边框按钮；输入框使用普通圆角背景，避免将全部内容都玻璃化。
- 联系人分组展开箭头与文字留出间距。侧栏搜索水平边距 12 点、高 32 点，三分区保持一致。

按 2026-10-15 用户调整，删除新建对话按钮及其菜单、快捷键；现有联系人和侧栏搜索可打开聊天。群助手只从列表汇总行进入，在搜索框上方固定显示“‹ 消息”和“群助手”标题，进入/返回使用方向相反的页面过渡；减少动态效果时直接切换。立即同步只放在设置 → 同步。聊天记录查找在每个会话右上角详情页，使用当前 chatID；搜索框置于右栏内容顶部，避免 Catalyst 隐藏的 iPad 导航栏吞掉搜索控件。

## 实现位置

2026-10-14 Claude Code 重构后按层组织（依赖方向见 [ARCHITECTURE.md](ARCHITECTURE.md)，交接见 [CLAUDE_HANDOFF.md](CLAUDE_HANDOFF.md)）：

- `App/Application/`：入口与装配。`MacApplication`（AppDelegate、Scene）、`MacMenuBuilder`（菜单与窗口快捷键）、`MacWorkspaceAssembly`（Session → 服务 → ViewModel → 协调器）、`MacRootView`（登录阶段与全局浮层、快速回复）。
- `App/Navigation/`：`MacWorkspaceCoordinator`（唯一路由所有者：分区、右栏页面、草稿、命令）、`MacAdaptiveSplitController`（760 点断点的双栏 / 单栏搬移）、`MacDetailContainer`（右栏切换与工具栏投射）、`MacChatCoordinator`（当前聊天与上次会话）、`MacSidebarToolbar`（侧栏标题栏按钮）、`MacPageFactory`、`MacCommandRouter`、`MacRoutes`。
- `App/DesignSystem/`：`MacMetrics` / `MacSymbol`（统一尺寸与符号）、`MacSidebarSearchField`、`MacFloatingTabBar`（真实 UITabBar）、`MacComposerMenu`、`MacSidebarRow`、`MacEmptyState`。
- `App/Features/Workspace`：`MacSidebarViewModel`（分区、各分区搜索词草稿、选中项、焦点请求）与 `MacSidebarView`。
- `App/Features/Search`：`MacSidebarSearchViewModel`（防抖、取消、代次隔离、打开联系人）、`MacSearchResultsController`（UIKit 差量结果与键盘）、`MacSidebarSearchView`。
- `App/Features/Contacts`：`MacContactsViewModel`（加载、筛选、分组展开）与 `MacContactsSidebarView`。
- `App/Features/Settings`：`MacSettingsSidebarView`；设置筛选在 `MacSidebarViewModel`。
- `App/Features/Conversations/Views`：`MacDialogsController`（差量会话列表、群助手、右键操作）、`MacChatPage` / `MacChatTitle`。
- 联系人左栏改用 Mac 自己的 `MacContactsViewModel` + `MacContactsSidebarView`；共用 `ContactsView` 的侧栏参数保留未删（iOS 不使用）。共用 `SettingsView` 提供账号详情模式。iOS 默认仍使用原来的完整页面导航。

## 参考与验证

参考 [Telegram macOS 官方源码入口](https://github.com/overtake/TelegramSwift) 的客户端分区设计；具体路由以本次用户明确的职责分配为准。材质与层级依据 [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) 和 [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)。

本轮还实际查看了 [Apple 信息使用手册](https://support.apple.com/guide/messages/welcome/mac) 的界面截图、[Telegram macOS](https://macos.telegram.org/) 官方截图及 `ChatTitleBarView`、`TabBarController` 源码。顶部实现参照 [Apple Mac Catalyst 导航栏行为](https://developer.apple.com/documentation/uikit/uinavigationbar/behavioralstyle) 与 [工具栏设计指南](https://developer.apple.com/design/human-interface-guidelines/toolbars)。Telegram 的旧截图只用于路由及比例参考，不当作当前系统材质规范。

实际窗口验证及构建结果见 [ACCEPTANCE.md](ACCEPTANCE.md)。旧四标签的验收仅保留为历史，不代表当前页面结构。

DEBUG 的「窗口 → 布局检查」提供 440×480、440×640、600×640、1024×640，便于重复检查最小高度与分栏切换；「外观检查」只临时覆盖本 App，验收后恢复跟随系统。联合验收由 Codex 操作实机、Claude Code 独立看截图和源码，分别记录证据；最小窗口报告见 [MIN_WINDOW_UI_REVIEW.md](MIN_WINDOW_UI_REVIEW.md)。
