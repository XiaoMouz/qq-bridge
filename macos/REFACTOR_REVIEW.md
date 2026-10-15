# 2026-10-14 UI 重构复核

> 2026-10-15 更新：本文保留历史实现与验收记录。新建会话/编写/⌘N、侧栏更多菜单及 ⌘R 已按用户要求移除；手动同步仅在设置 → 同步。群助手返回现在固定于搜索框上方。当前行为以 SIDEBAR_NAVIGATION_UI_REVIEW.md 为准，不应恢复本文的旧入口。
本轮由 Claude Code（`claude-opus-5-5`、`auto`）负责桌面 UI 重构，Codex 负责服务契约、审查与验收。Claude 会话：`9861564e-98f5-4f80-a1fa-d88301456dc8`。使用本机已安装的官方 CLI；2.1.235 不支持指定模型，升级到 2.1.299 后探测成功。

## 功能入口基线

以下来自当前 iOS 源码，作为重构前后的检查基线。共用代码不能单独证明路由仍可达；界面验收和硬件限制仍按 PARITY.md 记录。

| 功能 | 源码基线 | Mac 应保留的入口 |
|---|---|---|
| 消息、未读、群助手、置顶、通知策略 | DialogListView、Push、DialogActions | 消息标签、会话右键、群助手 |
| 会话搜索、联系人搜索、记录定位 | OtherTabs、ChatExtras、MessageJumpHandler | 侧栏搜索、会话资料中的查找聊天记录 |
| 文本、引用、@、回应、多选、撤回、两种转发 | ChatScreen、ChatCollectionView、MessageRow | 聊天输入区、消息菜单、多选工具栏 |
| 附件、粘贴、拖放、照片、视频、拍摄、语音 | Attachments、ComposerField、VoiceRecorder、VoiceExtras | 输入区附件菜单、录音、系统选择器 |
| 媒体查看、下载、表情与贴纸 | ImageViewer、MediaViews、MediaPopover、ReactionPicker | 消息媒体、表情按钮、查看器菜单 |
| 好友、群、成员与资料动作 | ContactsViews、ProfileViews | 联系人标签、标题右侧资料、成员列表 |
| 共享媒体、公告、精华、群文件、群相册 | ChatExtras、GroupContentViews、GroupFilesView | 群资料的子页面和返回路径 |
| 偏好、存储、清理、关于、QQ 登录、退出 | SettingsViews、StorageBrowseViews、QqLoginSheet | 设置侧栏及右侧详情 |
| Downloads、自选目录、授权恢复 | MacDownloads、MacDownloadSettingsView | 设置 → 下载；所有文件导出共用服务 |
| 快速回复、主会话草稿移交 | RootView、QuickReply、Composer | 横幅、会话右键、展开/关闭浮层 |
| 一对一与群语音、来电、静音 | CallManager、CallKitBridge、CallScreen | 附件菜单、群语音横幅、系统来电 |
| 推送跳转、后台未读与恢复 | Push、AppModel、NotificationService | 系统通知 → 指定会话；恢复当前路由 |

## 已完成的架构基础验证

- 登录 ViewModel：空输入、防重、失败重试、成功清理密码、取消/旧请求隔离、页面释放检查通过，未访问真实认证服务。
- Mac Debug 构建成功；严格签名验证成功。日志：`/tmp/betterchat-mvvm-foundation-build.log`。
- 实机启动拆分版本，已恢复 Something、实时列表更新、设置/消息切换与当前会话状态。基线截图：`/tmp/betterchat-ui-review/mvvm-foundation-wide.png`。
- 这只是 Claude 重构前的可运行基线，不代表新 UI 已验收。

## 新 UI 验收结果

- [x] XcodeGen 生成与 Mac 构建；共享会话行样式改动后 iOS 模拟器构建通过。
- [x] 1024 点双栏、440 点列表/详情、600 点设置详情；群文件 → 群资料 → 联系人列表按层返回；侧栏按钮与 ⌃⌘S 收起/恢复。
- [x] 三标签、空白查询保留列表、Esc 清空、真实聊天记录搜索；Tab 选中结果后定位并高亮消息；⌘N 选择 Something 后打开实际会话。
- [x] 设置左选右看，下载位置显示系统 Downloads；联系人搜索 Something 后进入群资料、群文件。
- [x] 联系人搜索和群文件子页面跨分区保留；临时文字草稿跨设置/消息、440 → 1024、侧栏收起/恢复保留，随后清空，未发送。
- [x] 深浅色截图检查工具栏、头像、标签、输入区；发现搜索选中态副标题与设置图标的对比问题并修订。
- [x] 核对功能入口仍连接既有实现，硬件/真实通话、断网恢复和未覆盖的写操作继续按 PARITY.md 保留，不冒充全功能实测通过。

### 自动化与构建证据

- `python3 macos/tests/run_state_checks.py`：七组通过，日志 `/tmp/betterchat-state-checks.log`。新增下载设置检查使用假服务，覆盖授权失败保留原目录、重试、恢复默认与目录状态单一来源。
- Mac：`/tmp/betterchat-mac-ui-final.log`；iOS：`/tmp/betterchat-ios-ui-refactor.log`。Mac 严格签名验证通过，未改版本、未打包发布；`Package.resolved` 未变化。
- 本轮共用 iOS 文件仅为 `DialogListView.swift` 的可选尺寸样式参数；iOS 默认外观数值保持不变。没有重写协议、同步、发件箱或通话后端。

### 截图

- `/tmp/betterchat-ui-review/claude-final-wide-dark.png`、`claude-final-wide-light.png`：双栏与输入区。
- `/tmp/betterchat-ui-review/claude-final-list-440-dark.png`：窄窗口列表与空白搜索。
- `/tmp/betterchat-ui-review/claude-round1-chat-440.png`、`claude-round1-contacts-440.png`：原生单栏返回路径。
- `/tmp/betterchat-ui-review/claude-final-search-light.png`：搜索替代左栏与历史消息高亮，第三轮对比度修订前的发现截图。
- `/tmp/betterchat-ui-review/claude-final-search-contrast-light.png`：副标题和时间使用系统选中主前景层级后的复验。
- `/tmp/betterchat-ui-review/claude-final-settings-monochrome-dark.png`、`claude-final-settings-monochrome-light.png`：设置行使用原生单色图标，跟随系统外观；普通行与选中行均可读。
- `/tmp/betterchat-ui-review/claude-final-downloads-600-light.png`：600 点单栏下载详情与原生返回。

Debug 菜单的“外观检查”仅覆盖 BetterChat 的窗口，不修改 macOS 系统外观、不持久化，也不进入 Release。完成检查后已恢复“跟随系统”。

最后的动态列表截图发现，高频新消息触发连续排序动画时会出现文字重叠与空洞。会话列表保持差量更新与变化行重配，但取消自动排序的搬行动画；用户切分区、导航返回的动画仍保留。

修订后的最终构建与严格签名校验通过。重新启动后，在实时消息持续更新的两次截图中未再出现重叠或空洞；最终图为 `/tmp/betterchat-ui-review/claude-delivery-wide.png`。应用停在 Something，搜索和输入区为空，系统外观跟随设置已恢复。
