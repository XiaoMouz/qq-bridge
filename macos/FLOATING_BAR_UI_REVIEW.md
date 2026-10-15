# F5 悬浮栏下滚动：Claude Code 独立复核（2026-10-14）

分工：**Claude Code 只用 Read 看了截图并只读源码**，没有操作 App、没有构建，也没有改源码。实际操作、构建和辅助功能树检查都是 Codex 做的。截图里的聊天内容只当作界面数据，这里不复述。

看过的截图（`/tmp/betterchat-ui-review/`）：`f5-messages-440-dark`、`f5-messages-bottom-440-dark`、`f5-search-440-dark`、`f5-search-bottom-440-dark`、`f5-search-bottom-440-light`、`f5-search-wide-light`、`f5-messages-wide-light`。

核对的源码：`Features/Workspace/Views/MacSidebarView.swift`、`Features/Search/Views/MacSidebarSearchView.swift`、`DesignSystem/Controls/MacFloatingBarInset.swift`。

## 结论：F5 在已覆盖的状态下已消除

| 检查项 | 结果 | 依据 |
|---|---|---|
| 会话列表的内容在 Liquid Glass 后面滚动 | **看图确认** | 440 深色（`f5-messages-440-dark`）中，「AI交流群」「群助手」两行从悬浮栏后面和两侧透出来；1024 浅色（`f5-messages-wide-light`）中，栏后面能看到下一行的头像和标题。 |
| 会话列表滚到底，最后一行完整 | **看图确认 + Codex 实测** | `f5-messages-bottom-440-dark` 中，最后一行完整显示在栏上方，滚动条下端也在栏上方；Codex 的辅助功能树显示到底后只剩 ScrollUp，没有 ScrollDown。 |
| 搜索结果在玻璃后滚动、滚到底完整 | **看图确认** | `f5-search-440-dark` 和 `f5-search-wide-light` 中，结果从栏后面透出；`f5-search-bottom-440-{dark,light}` 中，最后一条结果完整显示在栏上方，三行的预览没有被截断。 |
| 搜索框是固定的 | **看图确认** | 滚动前后，搜索框保持原位，没有被列表内容盖住；「聊天记录」分组标题属于结果列表，会随列表滚动。 |
| 底部三个 tab 可见可点 | 看图可见；Codex 本轮逐个点击消息 → 联系人 → 设置 → 消息，确认内容与选中态切换 | 各截图里 tab 栏都在列表上面，角标和选中态正常。 |
| 栏高没有写死 | **源码确认** | `MacSidebarView` 用 `onGeometryChange` 在布局完成后量出 tab 栏外层（含上下外边距）的高度，写进 `@State`；这个值只通过 `MacEmbeddedController.updateUIViewController` 和搜索结果的 representable 写到 UIKit 的 `contentInset.bottom` 和 `verticalScrollIndicatorInsets.bottom`。栏本身的尺寸不依赖这个值，所以不会形成布局循环。 |
| 有没有重复或漏加边距 | **源码确认** | 两个 UIKit 列表都设了 `contentInsetAdjustmentBehavior = .never`，底部边距只来自实测值，不和系统自动调整叠加；会话列表和搜索结果只在底部 `ignoresSafeArea(.container, edges: .bottom)`，搜索框在列表外面单独一行。 |

Codex 另外实测：⌘F 搜索、Esc 清空、窗口宽窄切换都可用。

## 源码里看到的潜在缺口（这次没有触发，也没有截图证据）

1. **搜索加载中或出错时，结果列表底部会多出一段空白（低）**。加载行或错误行排在结果列表下面时，列表不贴窗口底部，`ignoresSafeArea` 不起作用，但列表仍然拿到同样的 `floatingBarInset` 作为底部内容边距，所以列表底部会多出大约一个栏高的空白。不会挡住内容，提示行本身也在栏上方。建议实测「断网搜索」：确认提示行可见、能点「重试搜索」，以及多出的空白能不能接受。如果要改，可以只在没有加载行和错误行时才传这个边距。
2. **会话列表为空时，「暂无会话」或「群助手里没有群」的提示（低，没有测过）**。`MacDialogsController` 用的是 `contentUnavailableConfiguration`，列表铺到栏下面以后，提示按整块区域居中，可能往下偏约半个栏高，甚至部分落到栏后面。当前账号的数据造不出这个状态，没有截图证据。
3. **第一帧边距为 0（极低）**。`floatingBarInset` 初始是 0，要等第一次几何回调后才更新。窗口刚出现那一帧，如果正好在列表底部，最后一行可能会短暂被挡住，下一帧就会修正。只有逐帧录屏才能确认。

## 截图里看到的、和 F5 无关的现象

- `f5-messages-bottom-440-dark` 里，列表底部几行只有群名，没有时间和预览。推测是这些会话没有最新消息（时间和预览为空），这是数据状态，不属于悬浮栏的问题。这次没有展开查。

## 没有覆盖的部分

- 搜索加载中和出错（没有制造断网），以及缺口 1 里的多余空白。
- 会话列表为空、群助手里没有群时的空状态（缺口 2）。
- 用键盘上下键在搜索结果里选到最后一条时，会不会自动滚到栏上方：源码里用的是 `scrollToItem(.centeredVertically)`，会按调整后的内边距计算，理论上没问题，但这轮没有实测。
- 减弱动态效果、增强对比度、VoiceOver。
- 资料卡关闭问题不属于本报告；后续已由 Codex 修复并实测，边界见 [资料卡复验](PROFILE_CARD_UI_REVIEW.md)。
- Codex 本轮另外补测了最小窗口回复条、两个临时 TXT 附件的导入和移除序号更新（都已清空，没有发送）、群文件列表、群公告 / 精华 / 相册的空状态、成员卡能打开。这些属于其他报告的范围，这里只记录，不作为 F5 的依据。

Codex 后续补测：440×480 浅色长搜索词无结果提示完整，且不被悬浮栏遮挡（`f5-search-empty-440-light.png`）；最终 1024×640 深色会话列表图见 `f5-profile-final-workspace.png`。这两张新增截图未由 Claude 再次审阅。

后续：搜索错误/加载 footer 存在时已不再重复添加栏高边距；真实不可连接状态的 440 深浅与 1024 浅色错误布局已由 Codex 补测，见 [搜索恢复验收](SEARCH_RECOVERY_UI_REVIEW.md)。加载中的短暂状态与键盘末项仍未单独截图验收。
