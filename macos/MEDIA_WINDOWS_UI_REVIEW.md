# Mac 媒体独立窗口复验（2026-10-15）

> 2026-10-15 更新：本文保留历史实现与验收记录。新建会话/编写/⌘N、侧栏更多菜单及 ⌘R 已按用户要求移除；手动同步仅在设置 → 同步。群助手返回现在固定于搜索框上方。当前行为以 SIDEBAR_NAVIGATION_UI_REVIEW.md 为准，不应恢复本文的旧入口。
用户确认 60 秒视频中移动鼠标可正常唤出系统播放控件；随后要求图片与视频均独立窗口并支持全屏。此要求只适用于 Mac，iOS 保持原展示方式，Mac 图片编辑仍移除。

## 实现与边界

- `MacMediaWindows` 用一次性活动 ID 交付媒体请求，单独的 `MacMediaSceneDelegate` 创建原生 UIWindowScene；请求只在内存里保存，不持久化 Session 或媒体签名链接。
- 聊天 / 共享媒体 / 合并转发 / 群精华的 `mediaViewer`，以及公告 / 相册的 `urlGallery`，在 Mac 打开独立媒体场景。主窗口不再承载这些媒体覆盖层。
- 每个窗口可独立关闭、最小化、移动和使用绿色按钮进入系统全屏。媒体的 Esc 命令在全屏时交给系统先退出全屏；窗口状态下关闭当前媒体。
- 图片沿用翻页、缩放、保存、分享与转发。独立窗口隐藏共享页面中重复的关闭按钮，关闭交给系统窗口按钮。
- `VideoPreviewModel` 在 Mac 拥有独立 `VideoPlayback`，不再让多个窗口争用共享控制器；iOS 继续使用原来的 App 级播放器。
- 场景断开清理它自己的媒体资源；账号退出取消待连接请求并关闭媒体场景；重新启动不恢复失效的临时媒体，保留主窗口入口。
- 主工作区仍使用唯一协调器，移除系统自动生成的“新窗口”菜单，既有“新建消息”不变。

采用 Apple 的 [UIWindowScene](https://developer.apple.com/documentation/uikit/uiwindowscene) 与场景激活 API，并核对本机 SDK 27 的 `UISceneSessionActivationRequest`、`UISceneSizeRestrictions.allowsFullScreen`。没有使用私有 AppKit 桥接。

## 已有证据

- 19 项专项测试通过：5 项媒体窗口请求 / 资源隔离 + 5 项 VideoPreview + 4 项 Mac 画中画状态 + 5 项 URLGalleryPlayback。日志 `/tmp/betterchat-media-windows-tests.log`。不等同全套应用测试或系统画中画实测。
- iOS 回归构建通过：`/tmp/betterchat-media-windows-ios-final.log`。
- 真实 Something：视频、图片与主聊天同时存在，窗口菜单可分别切换；视频原生控件拖到 1 秒；图片方向键从 5/6 到 6/6，末页下一张禁用。
- 两类媒体均可用系统绿色按钮进入全屏，Esc 退出后窗口保留；再按 Esc 关闭图片，仅返回主聊天。保持视频窗口时退出并重启 App，恢复主聊天而不弹失效媒体窗口。
- 浅色视频标题栏可读；独立窗口没有多余的自绘关闭按钮。图片转发、保存、分享入口仍在，编辑入口不存在。

## 全屏截图的交叉核对

自动化切入图片全屏后曾显示顶部 / 右侧白边。诊断确认 UIWindowScene、根视图和 HostingController 子视图均为 1920×1080，安全区为零。打开诊断弹窗或仅对窗口执行系统 Raise 都会得到完整全屏画面；普通布局刷新和显式提交尺寸均未消除此自动化截图现象，两个尝试均已撤掉，没有保留未经证实有效的补丁。诊断菜单也已移除。

已向用户询问实际远程观看是否也有白边，等待交叉确认；不能把这条自动截图现象唯一归因于应用布局，也不宣称它已修复。全屏进入 / Esc 退出和图片翻页均有实际系统状态证据。

截图位于 `/tmp/betterchat-ui-review/`：`media-window-video-light.png`、`media-window-video-seek.png`。`media-window-image-fullscreen.png` 是待核对的自动化截图，不作为无白边通过证据。

本轮没有发送消息、上传媒体、改变 QQ 在线状态或测试真实音频 / AirPlay。完整能力仍以 PARITY.md 为准。

## 最终构建补验

移除诊断与无效尺寸尝试后的构建 `/tmp/betterchat-media-windows-clean-build.log` 成功，严格签名检查通过，Package.resolved 未变。已退出旧进程并打开最终构建：视频最小化后通过窗口菜单恢复，关闭后主聊天保留；真实群相册“游戏图片”在独立窗口打开 1/28，右方向键翻到 2/28，系统绿色按钮全屏、Esc 退出全屏、再次 Esc 关闭并返回原照片网格均通过。激活后的最终全屏截图为 `/tmp/betterchat-ui-review/media-window-album-fullscreen-final.png`，没有白边；此结果仍不替代前述用户实际观看的交叉确认。

已恢复 Something 最新位置、空搜索与空输入。跨屏及每一种消息来源尚未逐个实测；不把共用入口实现视为全部来源的 UI 验收。

## 画中画补验

生产画廊的本地 60 秒视频已通过系统小窗播放、暂停、前后跳转、恢复和关闭的实际操作。原实现复测通过，无需保留试验性引用修改。范围与截图见 [画中画复验](PICTURE_IN_PICTURE_REVIEW.md)；最终正常构建另补验 Something 真实聊天视频的小窗打开、播放与恢复；不将此结果扩展为远端长视频缓冲、音频或跨屏全部通过。
