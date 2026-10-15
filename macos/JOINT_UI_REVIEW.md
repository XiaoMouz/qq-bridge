# BetterChat Mac UI 联合验收：Claude Code 独立报告（2026-10-14）

> 后续进展（2026-10-14）：F5 已另行修复并完成宽窄窗口、深浅外观、滚到底的截图复核，见 [悬浮栏滚动复验](FLOATING_BAR_UI_REVIEW.md)。下文的 F5 未完成状态保留为当时记录。

## 最终结论（2026-10-14 第四轮复验，以本节为准；下面各节都是历史记录）

方法：Claude Code 用 Read 查看了 `joint-final-settings-1024-{dark,light}.png`、`joint-final-settings-440-{dark,light}.png`、`joint-final-contacts-440-dark.png`，并只读核对了源码中的状态链。没有操作 App，没有构建；构建日志 `/tmp/betterchat-joint-ui-final-build.log` 是 Codex 跑的。

| 编号 | 最终状态 | 我直接看到的 |
|---|---|---|
| F1 窄窗口角标压字 | **已消除** | 5 张图的 tab 栏都是竖排，角标在消息图标右上角，不压文字。 |
| F2 选中 tab 图标被裁切 | **已消除** | 选中的「设置」「联系人」图标完整落在胶囊里。 |
| F6 窄窗口列表变成卡片 | **已消除** | 440 宽的设置和联系人都不是圆角卡片；搜索框或分段控件下面直接开始第一行，没有多余空白；左边缘和搜索框对齐。 |
| R1 宽窗口选中样式通栏 | **已消除** | 1024 深色下「下载」的蓝底是左右留边的圆角（约 x 10–300），浅色下失焦的灰底也一样，宽窗口侧栏没有行分隔线，和修复前的侧栏样式一致。窄窗口仍是 plain 样式（通栏选中、有分隔线），这是窄布局有意的选择。 |
| F3 群助手行的「›」 / F4「⋯」菜单箭头 | 保留系统语义 | — |
| F5 列表没有从玻璃下面滚过去 | **低优先级视觉改进，没有修** | — |

**状态链（源码核对）**：
1. `MacAdaptiveSplitController.viewDidLayoutSubviews` 只在宽窄确实切换时，等容器搬完之后调用 `layoutChanged`。
2. `MacWorkspaceCoordinator` 在下一个 MainActor 任务里读取当时的 `rootViewController.isCompact`（读的是当前值，不是捕获的旧值），写入 `MacSidebarViewModel.setCompactLayout`。
3. `MacSidebarView` 把 `isCompactLayout` 注入局部环境 `macCompactSidebar`。
4. `MacSidebarListStyle` 按它选择：窄用 `.plain`，并用 `.contentMargins(.top, 0)` 去掉顶部空白；宽用 `.sidebar`。

这条链不读取系统尺寸类，也不在布局回调里同步改 SwiftUI 状态。`List(selection:)`、`DisclosureGroup` 和系统颜色都没有替换。

**宽 → 窄 → 宽**：Codex 实测，选中的「下载」一直保留，宽窗口恢复圆角留边，窄窗口没有卡片和多余空白。我看到的 1024 和 440 截图与这个结论一致。

**功能回归**：这 5 张图和上面的源码里没有看到明确的功能回归。前几轮 Codex 已实测的交互（路由、编写、搜索的键盘操作、⌃⌘S / ⌘F / Esc、⌘N 后按 Esc、草稿保留、分组展开保留）这一轮没有重测，以 Codex 的记录为准。

**仍然没有实测**（只检查过源码）：增强对比度、减弱动态效果、VoiceOver、非活动窗口下选中搜索结果的颜色。

---

## 历史：第三轮复验（F6 第一版修复后，已被最终结论取代）

方法：Claude Code 用 Read 查看了 `joint-f6-{contacts-440-dark, settings-440-dark, settings-440-light, contacts-600-light, settings-1024-dark, settings-1024-light}.png`，并读了 `MacSidebarListStyle` 的现状（Codex 的后备方案：`.listStyle(.plain)` + `.scrollContentBackground(.hidden)` + `.contentMargins(.top, 0, for: .scrollContent)`）。没有操作 App，没有构建；构建日志 `/tmp/betterchat-joint-ui-f6-build.log` 是 Codex 跑的。

| 编号 | 当前状态 | 依据 |
|---|---|---|
| F1 窄窗口角标压字 | 已消除（第二轮看图确认） | 本轮 6 张图里 tab 栏仍是竖排，角标不压字。 |
| F2 选中 tab 图标裁切 | 已消除（第二轮看图确认） | 本轮图里选中的「联系人」「设置」图标完整，没有裁切。 |
| F3 群助手行的「›」 | 保留：系统导航语义 | — |
| F4「⋯」菜单箭头 | 保留：系统菜单语义 | — |
| F5 列表没有从玻璃下面滚过去 | **低优先级视觉改进，没有修** | — |
| F6 窄窗口列表变成卡片 | **已消除（看图确认）** | 440 和 600 宽下，联系人和设置都不再是圆角卡片；分段控件和搜索框下面不再有 40–50 点空白，第一行紧接着开始；左边缘（展开箭头 x≈20、设置图标 x≈23）和搜索框、会话列表的头像起点基本对齐。 |
| 1024 深色左栏的淡色矩形 | 没有复现 | `joint-f6-settings-1024-dark.png` 和 Codex 的 `joint-settings-background-confirmed.png` 中都看不到。 |

### 本轮新发现：R1 · 低 · 宽窗口设置列表的选中样式变成通栏直角，并多了分隔线

- **证据**：`joint-f6-settings-1024-dark.png` 中，选中「下载」的蓝底横跨整个侧栏（x 0–310），直角，左右都贴到侧栏边缘；修复前的 `claude-final-settings-monochrome-dark.png` 中是左右各留约 10 点的圆角高亮，和会话列表、搜索结果的选中样式一致。`joint-f6-settings-1024-light.png` 中失去焦点时的灰底也是通栏。另外，宽窄两种布局下设置和联系人的行之间都出现了分隔线，会话列表和搜索结果没有。
- **原因**：`.plain` 列表的系统选中背景是通栏的，并且默认画行分隔线。这是 F6 修复带来的副作用，属于宽窗口下的回归。
- **建议**（不在本轮改）：
  - 只在窄布局用 `.plain`，宽布局保持 `.sidebar`。宽布局下 `.sidebar` 原本就正常，第二轮截图可以证明。
  - 或者保留 `.plain`，同时给行加 `.listRowSeparator(.hidden)`。
  - 两种做法都是系统 API，不需要自绘。选中背景的形状只有第一种能恢复。

### 补测完成（Codex 实测，Claude 未操作）

- 联系人「特别关心」展开后切到设置再回来，仍是展开状态，之后可以正常折叠。
- 宽窗口点击设置列表的「下载」，右栏正常进入下载页（深色蓝底选中正常；浅色截图的灰底表示焦点不在列表里）。
- 搜索：Tab 进入结果，Down / Up 选择，Shift-Tab 回到搜索框；⌃⌘S 收起侧栏后按 ⌘F 展开，搜索词还在；Esc 清空搜索词。
- 未选联系人时按 ⌃⌘S 停在列表；⌘N 打开新建消息后按 Esc 关闭，回到原来的列表。
- 下载页未操作时没有高亮卡住；之前 440 搜索框没有占位文字，是因为在测「只输空格」，不是缺陷。

### 仍然只检查过源码、没有实测

- **增强对比度**：选中搜索结果用 `.primary` 层级，颜色交给系统决定，但没有开启系统设置实际看过。
- **减弱动态效果**：分区切换和右栏淡入按 `accessibilityReduceMotion` / `UIAccessibility.isReduceMotionEnabled` 关闭，没有实际开启过。
- **VoiceOver**：tab 角标的「N 条未读」、群助手行的无障碍说明、搜索框名称都只在源码里确认过，没有用 VoiceOver 实际读过。
- 非活动窗口下选中搜索结果的颜色，以及 R1 修复后的截图。

---

## 历史：第二轮复验（tab 修复后，已被上一节取代）

复验方法：Claude Code 用 Read 逐张查看了 Codex 修复后的截图 `joint-tabs-{440,600,1024}-{dark,light}.png`，以及补测截图 `joint-download-idle-440.png`、`joint-contacts-empty-440.png`、`joint-preferences-440.png`；只读了源码，没有操作 App、没有构建。构建和严格签名校验是 Codex 跑的（`/tmp/betterchat-joint-ui-build.log`），我没有重跑。

| 编号 | 当前状态 | 依据 |
|---|---|---|
| F1 窄窗口角标压字 | **已消除（看图确认）** | 6 张 joint-tabs 截图里，440、600、1024 三种宽度、深浅色下 tab 都是图标在上、文字在下，红色角标在消息图标右上角，没有压到文字。补测图 `joint-contacts-empty-440.png` 仍是横排、角标压字，应是修复前的构建截的，不能代表现状。 |
| F2 选中图标被裁切 | **已消除（看图确认）** | 选中的「设置」（1024）、「联系人」（440 深色）、「消息」（600）图标都完整落在胶囊里，栏顶没有残留像素。tab 栏改用系统高度后，600 宽会话列表最后一行完整显示，没有被栏遮住。 |
| F3 群助手行多一个「›」 | 保留（导航语义，不是缺陷） | 按决定保留系统 disclosure 指示。 |
| F4「⋯」菜单箭头 | 保留（系统菜单语义） | 按决定保留。 |
| F5 列表没有从玻璃下面滚过去 | 低优先级视觉改进，**没有修复** | 不算已修。 |
| 下载页按钮高亮卡住（原补测 1） | 没复现 | `joint-download-idle-440.png` 中未操作时「选择文件夹…」没有高亮。 |
| 440 搜索框没有占位文字（原补测 2） | 不是缺陷 | Codex 确认当时在测「只输空格」。 |

### 复验新发现

- **F6 · 低 · 窄窗口下联系人和设置的左栏列表变成了卡片样式**：`joint-tabs-440-dark.png`（联系人）中，好友分组显示成圆角卡片加分隔线，卡片左边 x≈20，分段控件下方空了约 40 点；`joint-tabs-440-light.png`（设置）中，选项行图标缩进到 x≈45，行间有分隔线，搜索框下方空了约 50 点。宽窗口的设置列表（`joint-tabs-1024-*`）和窄窗口的会话列表（UIKit）都是左边距约 12 的侧栏样式，所以窄窗口下三个分区左边缘对不齐。**推测**原因：窄布局时侧栏不在分栏控制器里，环境是 compact 尺寸类，SwiftUI 的 `.listStyle(.sidebar)` 退化成了 inset grouped。这次没有改代码。建议给这两个 `List` 所在的宿主固定尺寸类，或在窄布局下换成 `.plain` 并对齐边距，改完看 440 和 600 两种宽度。
- **待确认 · 1024 深色设置左栏有一块淡色矩形**：`joint-tabs-1024-dark.png` 中，「偏好」到「关于」几行左侧（x≈10–80, y≈150–370）有一块比底色略浅的区域，浅色截图里看不到。可能是悬停或焦点残留，也可能是截图时的过渡动画，请 Codex 再截一次确认。

### Codex 新代码的源码审查

- `MacAdaptiveSplitController.toggleSidebar`：窄窗口下，在详情里就回列表；在列表时只有 `hasDetail?() == true` 才进入详情，否则什么都不做。逻辑合理，宽窗口的收起和恢复不受影响。小问题：没有详情时菜单和快捷键仍然可点，但按了没反应。可以接受；如果要更严格，可以在 `MacWindow.canPerformAction` 里按这种情况禁用。我不改 Application，留给 Codex 决定。
- `MacRecipientPickerController`：Esc 命令设了 `wantsPriorityOverSystemBehavior`，直接 dismiss。主窗口的 Esc（`returnToMessages`）在有弹窗时 `canReturnToMessages` 为 false，不会抢走按键，两边没有冲突。要注意的是，搜索框里已经输入文字时，按 Esc 会直接关掉整个选择器，而不是先清空搜索词。这和系统表单的习惯接近，可以接受，但请在 Codex 的实测记录里注明这一行为。

### 交互结论（Codex 实测，Claude 未操作）

- 未选联系人时按 ⌃⌘S 停在联系人列表。
- ⌘N 打开新建消息后按 Esc 关闭，回到原来的列表。
- 宽窄路由、编写、搜索定位，以及草稿在跨分区、缩放和隐藏侧栏后都还在（上一轮已实测）。
- 联系人无匹配的提示正常（`joint-contacts-empty-440.png`，看图确认）；偏好页说明文字在 440 宽下正常换行（`joint-preferences-440.png`，看图确认）。

### 仍未测

- 系统开启「增强对比度」和「减弱动态效果」后的效果：没有改系统设置，只看了源码（选中搜索结果用的是 `.primary` 层级；动画按 `accessibilityReduceMotion` / `isReduceMotionEnabled` 关闭）。**不能算实测通过**。
- 非活动窗口下选中搜索结果的颜色。
- F6 修复后的窄窗口截图；1024 深色左栏淡色矩形的确认。
- 通话、硬件、真实收发等不在这次 UI 验收范围内，按 PARITY.md 另行验收。

---

# 历史：首轮独立报告

审查人：Claude Code（claude-opus-5-5）。方法：用 Read 工具逐张查看下列 8 张实机截图，并对照 `macos/BetterChat/App` 当前源码。本轮没有操作 App，没有运行构建或 UI 自动化，没有改源码。下文「通过」只表示**截图上能看到**，不代表我亲手操作过；交互结论以 Codex 的实测为准。

| 截图 | 场景 |
|---|---|
| `claude-delivery-wide.png` | 宽窗口，深色，消息 + Something 聊天 |
| `claude-final-wide-light.png` | 宽窗口，浅色，同上 |
| `claude-final-list-440-dark.png` | 440 宽，深色，消息列表（搜索框处于聚焦） |
| `claude-round1-chat-440.png` | 440 宽，深色，聊天详情 |
| `claude-final-settings-monochrome-dark.png` / `-light.png` | 宽窗口，设置 → 下载 |
| `claude-final-search-contrast-light.png` | 宽窗口，浅色，聊天记录搜索结果选中 |
| `claude-final-downloads-600-light.png` | 600 宽，浅色，下载详情（窄布局） |

## 一、明确发现

### F1 · 中 · 窄窗口底部 tab 的未读角标压住「消息」文字
- **路径**：440 宽 → 消息列表 → 底部 tab 栏。
- **证据**：`claude-final-list-440-dark.png` 底部。窄布局下 tab 栏是图标在左、文字在右的横排，红色角标「1」盖在「消息」两个字上，「息」被遮住一部分。宽布局（`claude-delivery-wide.png`）是图标在上、文字在下的竖排，角标在图标右上角，没有遮挡。
- **原因（源码）**：`DesignSystem/Controls/MacFloatingTabBar.swift` 没有指定条目布局。窄布局下侧栏不在 split 里，拿不到 split 的 `horizontalSizeClass = .regular` 覆盖，`UITabBar` 改用了 inline 布局，角标的默认位置正好落在文字上。宽窄两种布局下 tab 栏的外观也因此不一致（窄时是居中的短胶囊）。
- **建议**：让两种布局下 tab 栏都用同一种条目布局。可以只写不读地给这个 tab 栏设 `traitOverrides.horizontalSizeClass = .compact` 固定成竖排（只写不读，避开读取未设置覆盖值时的断言）；或者用 `UITabBarAppearance` 的 `inlineLayoutAppearance.normal.badgePositionAdjustment` 把角标挪开。改完要看 440 和 1024 两种宽度。

### F2 · 中 · 选中的 tab 图标被栏顶部裁切或贴边
- **路径**：宽窗口 → 底部 tab 选中「设置」或「消息」。
- **证据**：两张设置截图里，选中的 `gearshape.fill` 顶部超出了胶囊的上边缘，上方还有一小块残留像素（约 x=238, y=582）；`claude-delivery-wide.png` 里选中的 `message.fill` 气泡顶部也顶到了胶囊边。没选中的「联系人」图标离上边有正常的留白。
- **原因（源码）**：`MacFloatingTabBar.sizeThatFits` 把高度固定成 `MacMetrics.tabBarHeight`（52），`MacSidebarView` 外面又套了一层 `.frame(height: 52)`。选中态在 macOS 27 上图标更大或位置不同，52 点不够放。
- **建议**：去掉固定高度，改用 `UITabBar` 的 `sizeThatFits` / 固有高度（`sizeThatFits` 返回 nil，或者返回 `uiView.sizeThatFits(...)`），外层也不再写死 52。另外可以确认未选和选中是否必须换成 `.fill` 版本：换 fill 后图标形状变了，进一步放大了这个差异。

### F3 · 低 · 群助手行的未读数和普通会话的角标没有右对齐
- **路径**：消息列表 → 群助手汇总行。
- **证据**：`claude-delivery-wide.png` 和 `claude-final-wide-light.png` 中，群助手行的「27」比上下几行的「99+」/「4」靠左约 12 点，右边还多一个「›」。
- **原因（源码）**：`Features/Conversations/Views/MacDialogsController.swift` 只给群助手行加了 `cell.accessories = [.disclosureIndicator()]`，普通会话行没有，所以群助手行的内容区更窄。
- **建议**：去掉这个 disclosure 指示（点击它本来就是进入列表，iMessage 侧栏也不画箭头），或者给普通行也留出同样宽度。去掉之后，「群助手，N 个群」的辅助功能说明不受影响。

### F4 · 低 · 侧栏工具栏三个按钮宽度不一致
- **路径**：宽窗口 → 侧栏顶部「⋯⌄」「编写」「侧栏」。
- **证据**：宽窗口截图里，「⋯」按钮因为带了菜单指示「⌄」，是一个比旁边两个圆按钮更宽的胶囊，三个按钮看起来不是同一组尺寸。
- **原因（源码）**：`Navigation/MacSidebarToolbar.swift` 里「会话操作」是 `UIBarButtonItem(title:image:menu:)`，只有菜单没有主动作，Catalyst 会自动加上菜单指示。
- **建议**：优先保留系统外观。如果要统一尺寸，可以检查 SDK 有没有公开 API 隐藏这个指示，不要自己画。这条只是视觉一致性问题，不影响功能。

### F5 · 低 · 会话列表在悬浮 tab 栏上沿被直接截断，没有从玻璃下面滚过去
- **路径**：消息列表滚动到底部附近。
- **证据**：宽窗口截图里，最后一行（「BakeXL…」/「BATrace…」）在 tab 栏上沿被切成半行，tab 栏后面是纯侧栏底色，看不到列表内容透过去。
- **原因（源码）**：`Features/Workspace/Views/MacSidebarView.swift` 用 `.safeAreaInset(edge: .bottom)` 放 tab 栏，嵌入的 UIKit 列表（`MacEmbeddedController`）布局在安全区以内，所以内容停在栏的上沿，不会滚到 Liquid Glass 下面。
- **建议**：如果要符合「内容在玻璃下滚动」的系统做法，可以让列表铺满到底部（`ignoresSafeArea(.container, edges: .bottom)`），用 `contentInset` / 安全区让最后一行能滚出来。改动前请 Codex 确认这是不是用户想要的效果；现在的做法不影响功能。

## 二、需要 Codex 补测（我没有实机操作，截图也不足以判断）

1. **下载页「选择文件夹…」行一直是高亮状态**：`claude-final-downloads-600-light.png` 中，鼠标指针在这一行下方，但这一行仍是浅蓝高亮。可能是键盘焦点，也可能是文件选择器关闭后按下态没有恢复。请重新打开下载页，看不点它时是否还高亮。
2. **440 截图的搜索框**：聚焦状态下没有占位文字，却显示了清除按钮，推测是 Codex 在测「只输空格」。如果框里其实是空的，那就是占位文字丢了，请确认。
3. 选中搜索结果在**非活动窗口**和**增强对比度**下副标题的颜色（第三轮的改动只看过活动窗口浅色）。
4. F1、F2 修完之后，440、600、1024 三种宽度下 tab 栏的高度、角标位置和选中图标，深浅色各看一次。
5. 宽窗口收起侧栏后，系统侧栏按钮出现在右栏标题栏左侧的位置，以及再次展开后侧栏搜索词是否还在。
6. 联系人分区：搜索无结果的提示、分组展开状态在切换分区后是否保留、重复点同一个联系人时右栏子页面（群文件）是否保留。这几张截图没有覆盖联系人分区。
7. 键盘：搜索框按 Tab 进结果、上下键、Shift-Tab 回搜索框、Esc 的退出顺序（窄详情 → 列表；搜索词 → 清空；其他分区 → 回到消息）。
8. 系统设置开启「减弱动态效果」时，分区切换和右栏淡入是否都关闭了。

## 三、截图能确认的通过项

- **页面职责（Telegram 式）**：三张宽窗口截图都是左栏选择、右栏内容。搜索结果直接替换了左栏的会话列表（`search-contrast-light`），点结果后右栏定位并高亮了对应消息（右侧那条消息是浅蓝底）。
- **三个分区在侧栏底部悬浮**：消息、联系人、设置固定在侧栏底部的胶囊里，宽窗口下深浅色都正常显示，消息上有未读角标。
- **资料入口在标题右侧**：宽和 440 两种聊天截图，标题栏右侧都有 ⓘ 按钮，标题左对齐在右栏起点。
- **设置左列表右详情**：设置列表在左，选中项用系统强调色；右侧是分组表单，标题「下载」在工具栏里，只有一行标题栏，没有手机式的大标题。
- **窄窗口单栏导航**：440 列表（只有列表，没有空详情）、440 聊天（左上是系统返回按钮，标题和资料按钮同在一行）、600 下载详情（有返回按钮）都是单栏，和 760 点断点的设计一致。
- **编写按钮**：宽窗口和 440 窗口下，消息分区工具栏都有编写按钮。它能不能用以 Codex 的实测为准，截图只能说明它在。
- **对齐**：右栏标题文字的起点和下面表单的左边缘对齐（x≈330）；侧栏搜索框、设置列表、会话行的左边距一致；会话行头像统一成 40 点（第二轮的改动在截图里生效了），三行预览时没有截断。
- **深浅色**：宽窗口消息页、设置页的深浅两套截图里，文字和背景都清晰可读。第三轮之后，选中的搜索结果副标题和时间在蓝底上已经清楚了。
- **会话行信息**：「[有人回复我]」「[@全体成员]」前缀、免打扰图标、发送者前缀、99+ 角标、群助手汇总都能看到，没有因为改成 40 点头像而丢失。

## 结论

截图里没有看到空白路由、按钮无效或状态丢失。确认的视觉缺陷有两条中等的：F1 窄窗口角标压字、F2 选中 tab 图标被裁切，建议在发布前修掉。F3–F5 是低优先级的对齐和材质细节。第二节列的事项需要 Codex 补实测，才能下最终结论。

## 修复记录（Claude Code，2026-10-14，未构建、未截图）

只改了 `DesignSystem/Controls/MacFloatingTabBar.swift`、`DesignSystem/MacMetrics.swift`、`Features/Workspace/Views/MacSidebarView.swift`。仍使用真实的系统 `UITabBar`，没有手画，也没有写死颜色。用到的 API 都先在本机 SDK 头文件里确认过：`UIView.traitOverrides`、`UIImage.SymbolConfiguration(scale:)` / `(weight:)` / `applying`、`UIView.sizeThatFits`。

- **F1（角标压字）**：给 tab 栏设 `traitOverrides.horizontalSizeClass = .compact`（只写不读），宽、窄两种布局都固定用系统的竖排布局，角标回到图标右上角。
- **F2（选中图标被裁切）**：去掉 `MacMetrics.tabBarHeight`（52）和侧栏里的 `.frame(height:)`。`sizeThatFits` 改为返回 `UITabBar.sizeThatFits` 算出来的系统高度，只保留外边距。符号统一用 `MacMetrics.tabSymbolConfiguration`（scale .medium、weight .regular）生成未选和选中两张图，字号仍由系统决定。
- **F3 / F4**：分别是导航语义和系统菜单语义，这一轮保留不动。
- **F5**：记为改进项（内容在玻璃下面滚动），这一轮不做。

需要截图确认：440、600、1024 三种宽度，深浅色下 tab 栏都是竖排；角标不压文字；选中的「消息」「设置」图标没被裁切；tab 栏变高后会话列表最后一行和设置列表没被遮住；三个图标粗细一致。
