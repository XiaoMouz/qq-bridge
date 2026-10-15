# BetterChat Mac 最小窗口（440×480）UI 验收：Claude Code 独立结论（2026-10-14）

> 后续进展（2026-10-14）：F5 已另行修复并完成宽窄窗口、深浅外观、滚到底的截图复核，见 [悬浮栏滚动复验](FLOATING_BAR_UI_REVIEW.md)。下文的 F5 未完成状态保留为当时记录。

## 最终结论（2026-10-14 第三轮复验，以本节为准；后面各节都是历史记录）

分工：**Claude Code 只看了截图和源码**（用 Read 查看了 `min-final-contacts-{wide-dark, wide-light, scroll-dark, scroll-light}.png`、`min-final-about-{dark,light}.png`）。**实际操作 App、xcodegen、构建都是 Codex 做的**：Codex 为 xcassets 里单独引用的 PNG 设了 `createIntermediateGroups: false`；Mac（`/tmp/betterchat-min-window-final-mac.log`）和 iOS（`/tmp/betterchat-min-window-final-ios.log`）都 BUILD SUCCEEDED，Mac 严格签名校验通过；包里只有一份 `AppIcon.png`，sha256 和源文件一致。这些结论来自 Codex 的记录，我没有重跑。

| 编号 | 最终状态 | 我在截图里看到的 |
|---|---|---|
| M1 滚动内容露在分段控件周围 | **已消除** | 440×480 深浅色滚动后，分段控件周围没有行文字或数字露出来；上一行只在材质下沿外隐约可见，这是正常的滚动边缘。 |
| M3 联系人顶部两种底色 | **已消除** | 1024 宽深浅色下，搜索框、分段控件、列表在同一种侧栏底色上，没有横条。窄布局深色下，分段控件后面的栏材质比列表略浅，浅色下几乎看不出。这是窄布局里固定控件区为了防止透字而用的系统材质，我认为**可以接受**，不算缺陷。 |
| M4 关于页图标空白 | **已消除** | 深色和浅色的关于页都显示了应用图标（80 点圆角），下面是「BetterChat / 版本 1.0 (1)」。浅色下图标本身的白底和卡片融在一起，看不出圆角边，这是图标画面本身的原因，不是空白。 |
| M5 右栏标题带「— BetterChat」 | **联系人的空状态已消除**；聊天的空状态**未实测** | 宽窗口没选联系人时，右栏标题是「联系人」，下面是「联系人 / 选择好友或群聊，查看详细资料。」的空状态。聊天空状态（标题应为「消息」）Codex 没有为此清掉已选会话，所以这条只按源码确认：`MacEmptyState.chat.toolbarTitle = "消息"`，和联系人走同一条投射路径。 |
| M2 / F5 会话列表不会滚到玻璃下面 | **没修，低优先级** | — |

**Codex 已实测（这几张截图之外，或之前我看过截图的）**：440×480 下表情面板打开和 Esc 关闭；三行草稿（没有发送）完整可见并能清空；新建消息的「取消」和 Esc 都能关闭；应用已恢复到 1024×640、外观跟随系统、Something 会话、输入框和搜索框都是空的。

**仍然在验收范围之外，或没有覆盖**：F5；回复条在最小窗口下的布局；附件菜单的视觉；群资料的全部子页面；新建消息表单在小屏幕上的位置；增强对比度、减弱动态效果、VoiceOver 等无障碍检查；相机、麦克风、通话等硬件验收；iOS 全部功能对齐（按 `PARITY.md`）。

**结论**：这一轮的 M1、M3、M4 和 M5（联系人空状态）在截图里都已经消除，没有看到新的截断或回归。M5 的聊天空状态只是源码层面确认。剩下的只有低优先级的 F5，以及上面列出的未覆盖项。

---

## 历史：第二轮复验（已被下面的最终结论取代）

方法：Claude Code 用 Read 查看了 `min-fixed-contacts-{top-dark, scroll-dark, scroll-light, wide-light, wide-dark}.png`，以及补充截图 `min-messages-{dark,light}`、`min-search-dark`、`min-settings-light`、`min-contact-search-empty-dark`、`min-storage-light`、`min-storage-bottom-light`、`min-about-light`；只读核对了 `MacContactsSidebarView.swift`、`SettingsViews.swift`（AboutView），以及已构建 App 的 Info.plist（`plutil -p`，只读）。没有操作 App，没有构建，也没有改源码。交互结论都来自 Codex 的实测（构建日志 `/tmp/betterchat-min-window-fix-build.log`）。

| 编号 | 状态 | 证据 |
|---|---|---|
| M1 滚动内容露在分段控件周围 | **已消除** | 440×480 深浅色滚动后的截图里，分段控件后面是系统栏材质，列表滚上去被这块材质盖住，只在材质下沿隐约看到上一行；控件周围不再露出行文字和数字。 |
| M2 / F5 会话列表不会滚到玻璃下面 | **没修，低优先级** | 这两张消息图里，最后一行都完整停在 tab 栏上方，这些截图证明不了它会滚到玻璃下面。 |
| M3 联系人顶部变成两种颜色（新，修复带来的） | **新的视觉回归，低** | 见下文。 |
| M4 关于页没有应用图标（新） | **真实缺陷，中** | 见下文。 |
| M5 宽窗口右栏工具栏标题带「— BetterChat」（新） | **低** | 见下文。 |

### M3 · 低 · 联系人顶部变成两种颜色（`.background(.bar)` 带来的回归）
- **证据**：`min-fixed-contacts-wide-light.png` 中，分段控件后面有一条明显偏白的横条（约 y 105–145，横跨整个侧栏），而上面的搜索框区域和下面的列表都是侧栏的灰色；`min-fixed-contacts-wide-dark.png` 和 `min-fixed-contacts-top-dark.png` 里，这条横条比周围略浅。只有 440 浅色下看不出差别。也就是说，顶部被分成「搜索框（侧栏色）＋分段控件（栏材质）」两段，未滚动时也是这样。
- **原因**：`.background(.bar)` 只加在分段控件这一层，搜索框不在这个容器里；而且宽布局下列表是 `.sidebar` 样式，本来就不需要这层隔开。
- **建议**：让材质只在窄布局生效（`MacSidebarListStyle` 已经有局部环境 `macCompactSidebar`，可以按它决定要不要加这层背景）；或者把搜索框和分段控件放进同一个头部，共用一层材质。改完要看宽窄、深浅色、滚动和未滚动。

### M4 · 中 · 关于页的应用图标是空白（Catalyst 专有）
- **证据**：`min-about-light.png` 中，「BetterChat / 版本 1.0 (1)」上方本该是 80×80 的图标，现在是一块空白。
- **原因（源码 + 已构建的 plist）**：共享的 `AboutView.appIcon`（`ios/QQBridge/App/SettingsViews.swift:632`）从 `CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles` 读图标文件名。用 `plutil -p` 查看已构建的 Mac App，Info.plist 里只有 `CFBundleIconFile` / `CFBundleIconName` = `AppIcon`，没有 `CFBundleIcons`，所以拿到的是空的 `UIImage()`。
- **建议**：在共享文件里加 `#if targetEnvironment(macCatalyst)` 的回退：读取 `CFBundleIconName` 再加载图片（`UIImage(named:)` 在 Catalyst 上能不能取到 appiconset 需要实测）；也可以改用资源目录里另放的一张图。iOS 的路径不变。修完需要截关于页。

### M5 · 低 · 宽窗口没有选中联系人时，右栏工具栏标题显示「联系人 — BetterChat」
- **证据**：`min-fixed-contacts-wide-{light,dark}.png` 右栏左上角的标题是「联系人 — BetterChat」，其他页面（例如「下载」「账号」）只显示页面名。
- **推测原因**：联系人的空详情页没有自己的 `navigationItem.title`，标题栏退回去显示了协调器写入的窗口场景标题（`"\(title) — BetterChat"`）。要么给空状态页设置标题，要么让场景标题只用于窗口菜单。这一条没有实测切换过程，只根据截图和源码推测。

### M3 / M4 / M5 修复（Claude Code 已改源码，**待 Codex 复验**；没有构建、没有 xcodegen、没有截图）

- **M3**（`Features/Contacts/Views/MacContactsSidebarView.swift`）：分段控件后面的 `.bar` 材质只在局部环境 `macCompactSidebar == true`（窄布局，plain 列表）时绘制。宽布局下不再画，交还给侧栏材质，消除两种底色；窄布局保留这层材质，继续防止 M1 那种文字透出。没有新加颜色。**残留风险**：窄布局深色下，分段控件后面的栏材质和搜索框区域的颜色可能仍有轻微差异（第二轮 `min-fixed-contacts-top-dark.png` 里能看到），这是窄布局用系统材质防透字的代价，请截图判断能否接受。
- **M4**：
  - `macos/BetterChat/project.yml`：把 `ios/QQBridge/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` 作为单独的 `buildPhase: resources` 引用（引用原文件，不复制），包里会多一个 `AppIcon.png`。
  - `Navigation/MacPageFactory.swift`：新增 `MacPageFactory.appIcon`，用 `Bundle.main.path(forResource: "AppIcon", ofType: "png")` 加 `UIImage(contentsOfFile:)` 按文件路径明确读取，不依赖 `UIImage(named:)` 能否取到 appiconset；关于页传 `AboutView(session:icon:)`。
  - `ios/QQBridge/App/SettingsViews.swift`：`AboutView` 加了可选参数 `var icon: UIImage? = nil`，显示 `icon ?? Self.appIcon`。iOS 的调用点不传，行为不变。
- **M5**（`DesignSystem/Components/MacEmptyState.swift`、`Navigation/MacPageFactory.swift`）：`MacEmptyState` 新增短标题 `toolbarTitle`（聊天为「消息」，联系人为「联系人」）。`MacPageFactory.empty` 改为用 `MacHostingController` 承载 `NavigationStack { MacEmptyStateView … .navigationTitle(toolbarTitle) }`，和其他右栏页面一样把标题投射到工具栏。聊天占位里的长句「你的对话，尽在这里」不会变成工具栏标题。协调器仍会写窗口场景标题「… — BetterChat」，供窗口菜单使用，`MacWorkspaceCoordinator` 没有改。空状态改用 SwiftUI 的 `ContentUnavailableView`，文案和图标都不变。

需要 Codex：
1. 跑 xcodegen；Mac 和 iOS 构建（共享的 `SettingsViews.swift` 改了）。
2. 截关于页（Mac 有图标；iOS 外观不变）。
3. 联系人宽 1024 深浅色（顶部一种底色）、窄 440 深浅色（滚动中和顶部，没有文字透出）。
4. 宽窗口没选会话、没选联系人时，右栏标题分别是「消息」「联系人」，窗口菜单里的标题仍是「… — BetterChat」。
5. 检查构建后的包里只有一份 `AppIcon.png`，xcassets 编译没有报重复资源。

### Codex 本轮补测（我看了截图，交互由 Codex 操作）
- `min-emoji-dark.png`：表情面板在 440×480 下打开，「QQ 表情 / 我的表情 920」分段和刷新按钮完整，表情网格是 4 列，没有截断。第一行顶部被分段头部挡住，这是列表滚动在头部下方，不是裁切。Esc 关闭是 Codex 实测的。
- `min-multiline-draft-dark.png`：三行草稿（没有发送）让输入区随内容增高，三行都可见，发送按钮出现，附件按钮和表情按钮与输入框对齐；清空也是 Codex 实测的。
- 新建消息的「取消」按钮能返回原来的联系人页（Codex 实测）。

### 补充截图能确认的（只代表看到的画面）
- **消息列表 440×480**（深浅色）：搜索框、会话行（[有人回复我]、[@全体成员] 前缀、免打扰图标、99+ 角标）、群助手行、tab 栏都完整显示。
- **消息搜索**：搜索结果「聊天记录」直接替换了会话列表，三条结果的标题、预览和时间都没有截断。Esc 清除是 Codex 实测的。
- **联系人无结果**：系统的「未找到…」提示居中，长关键词没有截断。
- **设置浅色**：5 项都完整显示，选中「偏好」是窄布局的通栏灰底，和之前的验收一致。
- **存储**：顶部的总量条、各类别的大小、份数和百分比都完整；滚到底后，「热存储（服务器硬盘）」「冷存储（外接硬盘）」两个磁盘统计（剩余、各项占用、总量）完整，最下面一张卡片的下沿贴近窗口底部，但没有被裁切。
- **关于**：版本、服务器地址、连接状态都显示了（图标缺失见 M4）。

### 仍然没有覆盖（已经缩小范围）
- 聊天在 440×480 下的**回复条**，以及附件菜单的视觉（菜单没被截到）。表情面板和多行草稿已经由 Codex 补测，见上文。
- 群资料的子页面（群文件列表、相册、成员资料）在 440×480 下的样子。
- 新建消息表单在小屏幕或窗口靠近屏幕边缘时的位置。
- 增强对比度、减弱动态效果、VoiceOver：都**没有实测**。
- M3、M4、M5 修复后的构建和截图（待 Codex 复验）。
- 这不是 iOS 全部功能对齐的验收（要看 `PARITY.md`）。

### 优先级
| 优先级 | 编号 |
|---|---|
| 中 | M4 关于页没有应用图标 |
| 低 | M3 联系人顶部两种颜色（M1 修复带来的回归）、M5 右栏标题带「— BetterChat」、M2 / F5 会话列表不会滚到玻璃下面 |

M1 已消除。

---

# 历史：第一轮（440×480 初验）

审查人：Claude Code（claude-opus-5-5）。**我只用 Read 看了截图、读了源码**，没有操作 App、没有构建，也没有改任何源码。下文所有交互结论都来自 Codex 的实测，我没有自己点过。这份报告**不代表**全部 iOS 功能或无障碍已经验收。

看过的截图（`/tmp/betterchat-ui-review/`，深色）：`min-chat`、`min-info-bottom`、`min-settings`、`min-downloads`、`min-preferences`、`min-contacts`、`min-contacts-bottom`、`min-compose`。

## 一、真实缺陷

### M1 · 低 · 联系人列表滚动后，内容直接露在分段控件周围
- **证据**：`min-contacts-bottom-dark.png` 中，列表滚动后「центр списо(n」这一行有一半压在「好友 768 / 群聊 263」分段控件下面，行尾的「593」紧贴在控件右下边缘，滚动内容和控件之间没有任何隔开。未滚动的 `min-contacts-dark.png` 没有这个问题。
- **原因（源码）**：`Features/Contacts/Views/MacContactsSidebarView.swift` 用 `.safeAreaInset(edge: .top)` 放分段控件，但这一区域没有背景；窄布局下列表是 `.plain`（`MacSidebarListStyle` 的窄分支），内容会滚到这个区域下面并透出来。
- **建议**：给顶部这块区域加一层系统材质作背景（例如 `.background(.bar)` 一类的系统样式），或者把分段控件移到列表外、和搜索框放在同一个固定头部。不要自己画颜色。改完需要截两张图：滚动中和滚到顶。

### M2 · 低（已知，未修）· F5：会话列表（UIKit）不会滚到底部玻璃下面
- 这次的截图没有覆盖消息列表，也没有新证据。按 `JOINT_UI_REVIEW.md` 的记录，它仍是**未修复**的低优先级视觉改进，不算通过。
- 顺带对比：`min-contacts-dark.png` 中，联系人列表（SwiftUI）的「сеть св…」「9」这一行在悬浮 tab 栏的后面和两侧都能看到，说明 SwiftUI 列表会滚到玻璃下面，而会话列表不会。两个分区的底部行为不一致，这也是 F5 要解决的。

## 二、系统合理行为（不算缺陷）

- **新建消息表单比父窗口大**（`min-compose-dark.png`，480×600，父窗口是 440×480）：`MacPageFactory` 把 `preferredContentSize` 写死为 480×600，用的是 `.formSheet`。Codex 实测在 Catalyst 上它是一个独立的表单窗口，在当前显示器上完整可见。表单是独立呈现的，比父窗口大不会遮住或裁切父窗口的内容，可以接受。它**不是**在 440×480 里显示的，这份报告不按 440×480 来评价它。剩下的风险是：如果父窗口靠近屏幕底部，或者屏幕很小，600 高可能放不下。这一点没有测过。（如果以后要处理，可以考虑让尺寸不超过父窗口所在屏幕的可用区域。）
- **窄布局下设置的选中行是通栏灰底**（`min-settings-dark.png`）：窄布局用 `.plain` 列表，灰色表示焦点不在列表里，这是之前的验收（F6 / R1）有意保留的样式。
- **群资料、下载、偏好是系统的分组表单**：圆角分组、带缩进的分隔线、灰色说明文字都是系统 `Form` 的默认样式，在 440 宽下没有截断。
- **详情页不显示底部 tab 栏**（聊天、群资料、下载、偏好）：窄布局是单栏导航，进入详情后由返回按钮回到列表，这符合当初的设计。

## 三、截图可以确认的（只代表看到的画面，不是交互验收）

- **聊天**（`min-chat`）：标题行的返回按钮、「Something · 4 人」和资料按钮在同一行，都没有截断；输入区（附件、输入框、表情、麦克风）完整显示，四个按钮大小一致、垂直居中；气泡和时间都没有裁切。
- **群资料滚到底部**（`min-info-bottom`）：「查找聊天记录」「图片、视频与文件」「群公告」「群精华」「群文件」「群相册」都能看到，右边有滚动条；最下面的「搜索成员」露出一部分，这是还能继续往下滚，不是裁切。
- **设置**（`min-settings`）：5 个选项都完整显示，最后一项和底部 tab 栏之间有空白；tab 栏是竖排，角标在图标右上角，选中的「设置」图标没有被裁切。
- **下载**（`min-downloads`）：路径 `/Users/xiaomouz/Downloads` 在一行里完整显示，「选择文件夹…」和说明文字（两行）完整；没有选中的残留高亮。
- **偏好**（`min-preferences`）：「预览行数 两行」选择器、「自动语音转文字」开关和说明文字都完整，自动换行。
- **联系人**（`min-contacts`、`min-contacts-bottom`）：滚到底后最后一个分组「Неизвестный 4」完整显示在 tab 栏上方。
- **新建消息**（`min-compose`）：「取消」、标题、搜索框和会话列表（包括置顶标记）完整显示。

## 四、交互结论（Codex 实测，我没有操作）

- 添加附件的菜单有「照片 / 文件 / AI 语音 / @某人」。菜单没有被截到图，**所以菜单的视觉不算验收**。
- 群资料能滚动到群文件等后面的入口；设置的 5 项都可见；下载和偏好页的控件都完整。
- 联系人滚到底后，最后一个分组在 tab 栏上方。
- ⌘N 打开系统收件人表单，按 Esc 关闭后回到联系人。

## 五、还没覆盖的

- 浅色下的 440×480；消息列表在 440×480 下的样子（包括 F5）；聊天里展开附件菜单、表情面板、回复条、多行草稿，以及 440×480 下附件条的布局。
- 群资料里的子页面（群文件列表、相册、成员资料）在 440×480 下的样子。
- 新建消息表单在小屏幕或窗口靠近屏幕边缘时的位置。
- 增强对比度、减弱动态效果、VoiceOver：都**没有实测**。
- 这次不是 iOS 全部功能对齐的验收；完整的对齐要看 `PARITY.md`。

## 结论与优先级

440×480 下的主要页面（聊天、群资料、设置、下载、偏好、联系人）在截图里都没有看到截断，也没有出现空白路由。

| 优先级 | 编号 | 内容 |
|---|---|---|
| 低 | M1 | 联系人列表滚动后，内容直接露在分段控件周围（这次新发现） |
| 低 | M2 / F5 | 会话列表不会滚到玻璃下面，和联系人列表不一致（已知，没修） |
| 低风险，未测 | — | 新建消息表单固定 480×600，屏幕很小时可能放不下 |

没有中、高优先级的问题。
