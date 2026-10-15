# URL 画廊桌面复验（2026-10-15）

范围：群公告、群相册共用的 URLGalleryView。Claude Code Opus 5.5（auto 模式）实现画廊键盘/按钮接线；Codex 实现独立播放器状态、5 项测试及真实窗口验收，Claude 再独立读图与源码复核。

## 实现

- Mac 增加上一张、下一张和边界禁用状态；方向键翻页、Esc 关闭，隐藏图片工具栏后键盘仍有效。分页变化使用短动画并尊重减少动态效果设置。
- 初始索引在 State 初始化时限制到有效范围，不再出现后续 onAppear 重置。
- URLGalleryPlayback 只持有当前视频播放器；同一页重算保留实例，翻页或关闭暂停并清空 item。返回旧视频从头暂停，不宣称跨页保留进度。未复用聊天画中画的全局 VideoPlayback。

## 证据与边界

本机临时 Debug 入口调用真实 urlGallery / platformFullScreenCover，素材为生成的蓝色横图、橙色竖图、12 秒静音 H.264 视频，由仅监听 127.0.0.1 的临时 HTTP 服务提供。首次 Python SimpleHTTPServer 不支持 Range，视频加载失败；测试服务支持 Range 后解码正常。这不是对真实群相册视频地址的集成验收。

- 1024×640 第一页可见页码、关闭和前后按钮，上一张禁用：`/tmp/betterchat-ui-review/url-gallery-first-1024.png`。
- Right 切视频显示首帧且不自动播放；实际单击视频中心能推进画面，再击可暂停。440×640 视频保持比例，分页控件未裁切：`url-gallery-video-440.png`。
- Right 到第三页竖图，下一张禁用，继续 Right 不越界：`url-gallery-last-440.png`。
- 覆盖期间 1024→440，Esc 返回后有原生 Back；440→1024 关闭后恢复双栏，标题正常：`url-gallery-return-440.png`、`url-gallery-return-1024.png`。
- 图片点击隐藏工具栏后 Right 仍能进入视频，Esc 返回有效：`url-gallery-hidden-video-1024.png`。首轮发现图片沉浸模式转视频后没有鼠标重新显示画廊工具栏的专门入口；后续修复与复验见下节。
- 5 项真实 AVPlayer 生命周期测试通过：`/tmp/betterchat-url-gallery-tests.log`。iOS 构建通过：`/tmp/betterchat-url-gallery-ios.log`。测试是不存在的本地 URL，不证明解码；真实解码由上述静音素材补证，不证明音频输出。

## 首轮未验收与后续（部分已在下节完成）

视频页截图和辅助功能树没有出现可见播放/进度控制栏。Claude 提醒可能与自动化没有悬停事件有关，尚未唯一定位为框架或应用错误；不将中心点击播放等同完整控件验收。应先对照聊天的原生 AVPlayerViewController，再决定是否用独立包装替代 SwiftUI VideoPlayer；不能直接复用全局画中画控制器。

鼠标前后按钮、视频进度拖动、空格键、带声音视频、初始非零索引真实入口、iOS 滑动以及非空群公告/相册真实数据仍未在本轮通过。截图无法证明动画帧质量。临时入口及 HTTP 服务在验收后移除/停止，未发送消息或上传素材。

## 后续：视频工具栏、空格键与竖照响应式

真实聊天视频对照（同一自动化工具、Something 新测试视频）也只显现画面与关闭按钮，没有原生控制条。截图 `/tmp/betterchat-ui-review/chat-video-native-controls-comparison.png`。因此没有贸然替换 VideoPlayer，也未把该现象唯一归因于 SwiftUI。

Claude 修改 URLGalleryView：视频页始终显示画廊工具栏，图片页仍记住沉浸状态；上一张/下一张/关闭统一为 40 点圆形按钮，加细描边确保黑底上可辨识，播放器顶部避让工具栏。440×480 实测初始第三页为 3/3 且下一张禁用，鼠标上一张/下一张有效；隐藏图片到视频后显示关闭/翻页，回图片保持隐藏。证据 `gallery-chrome-video-from-hidden-440.png`。

本轮又实测视频首帧按空格无反应，已补 MacMediaKeyboard 可选播放命令，仅画廊当前视频传入，不影响其他调用者。竖图 360×640 在最小窗口被铺满的原因是按窗口比例判定长图；Mac 另要求图片自身高宽比大于 2.5，普通竖照默认完整显示，真正长图保留按宽阅读；iOS 长图判据不变。新增 ImageLayoutTests 使用实际 CenteringScrollView 检查普通竖照跨尺寸、横图完整可见与长图滚动。最终构建和复验结果另记于下方。

最终候选复验：三项布局测试通过，iOS 构建 `/tmp/betterchat-gallery-controls-ios.log` 通过。Mac 在可选方法引用三元表达式处发生无诊断编译失败，拆成独立 mediaKeyboard 属性并显式标注闭包类型后构建与测试通过。相同问题累计三次，已升级为 lessons L5。

- 440×480 竖照完整显示，1024×640 也保持完整比例：`gallery-portrait-fixed-440.png`、`gallery-portrait-fixed-1024-light.png`。
- 视频空格启动，第二次暂停于 6.875 秒；放大窗口后保持 6.875 秒，播放器未重建：`gallery-space-paused-440.png`、`gallery-space-paused-1024.png`。
- 播放到最后一帧 11.958 秒后空格从头重播：`gallery-space-replay-1024.png`。
- 鼠标上一张、下一张及关闭已通过；初始第三张正确为 3/3，末页下一张禁用；图片隐藏状态翻到视频显示按钮，翻回图片保留隐藏状态。
- 真实音频、原生控制条/进度拖动、iOS 触摸滑动与非空群内容仍未通过；上述证据不能替代。

### 浅色标题栏修复

浅色实测发现黑字标题落在黑底上。局部 preferredColorScheme(.dark) 未改变原生标题，已撤掉。最终只在 Mac 让 presentationBackground 使用系统背景；画廊的黑色内容背景显式只忽略底部安全区，根内容也只忽略底部。这样标题栏跟随系统外观，不改整个窗口外观状态。默认 `.background(.black)` 会延伸到顶部，不能达到该效果。

最终 1024 浅色、440 浅色/深色均确认标题可读、竖照完整、按钮同尺寸：`gallery-final-title-1024-light.png`、`gallery-final-title-440-light.png`、`gallery-final-title-440-dark.png`。浅色验证后切深色，Esc 返回窄窗口原生 Back 正常。本轮不将其他媒体覆盖的相似标题问题视为已修复；它们需各自复验。临时画廊入口/源文件已删除，HTTP 素材服务已停止。

Claude 最终独立读图确认三张最终截图标题可读、控件尺寸一致、竖图完整，没有发现新的明显问题；仅提示禁用按钮在黑底和黄图上的视觉强弱不同，未要求改动。此复核不扩展到未测试的音频、系统播放控件或真实群内容。


## 2026-10-15 系统播放器入口补验

最小 UIKit 内嵌 AVPlayerViewController 与现有 SwiftUI / 聊天内嵌播放器均未显示控制条，显式 showsPlaybackControls 和自动进入全屏设置未解决。直接呈现 AVPlayerViewController 可显示完整原生控件。因此新增仅 Mac 使用的“打开播放器”玻璃按钮，同一个 AVPlayer 切换到系统呈现，保留位置；聊天播放器仍由 VideoPlayback 接收画中画回调。

实测发现 fullScreen 会触发底层 SwiftUI onDisappear，导致播放状态被清理并立即退回；最终使用 overFullScreen 保留媒体页。Mac 短视频播完不再自动关闭预览；iOS 的原有行为保留。

- Something 两秒测试视频：原生控件可见、拖到 1 秒、关闭返回预览、重复打开仍在 1 秒，1024 / 440 点窗口布局正常。
- 真实 URLGalleryView 加本机生成 12 秒静音视频：原生控件可见，拖到 6 秒，播放至 12 秒后 Esc 返回画廊，再次打开仍在末尾。
- 原生倍速菜单可打开并选择 1.5 倍；没有测量实际播放时长，不据此宣称倍速行为完整通过。
- 播放期间原生控件自动隐藏，当前鼠标单击/双击未唤出；Esc 可返回并重新打开控件。此交互、音量、有声素材、画中画和 AirPlay 仍未验收。

截图：`/tmp/betterchat-ui-review/video-chat-native-seek.png`、`video-native-controls-narrow.png`、`video-gallery-native-seek.png`。临时对照菜单和源文件已移除，本机素材 HTTP 服务已停止；未上传素材、未发送消息。Claude Code 本轮达到会话额度，未参与本次播放器终验，不能计为双方验收。


## 2026-10-15 Mac 画中画状态隔离

继续检查时发现 VideoPlayback 使用一个布尔值，willStart 后没有失败回调收尾；旧控制器的 start/stop 也可改变新播放器的状态。以真实代理方法驱动四个回归场景，旧代码四项全部失败，确认不是仅静态推断。Mac 分支现记录具体控制器归属，替换时失效旧状态，只接受当前控制器事件，并在启动失败后沿停止路径收尾；iOS 分支保持原行为。

本轮点击真实两秒视频的画中画按钮后系统呈现退回预览，但当前工具没有取得系统独立小窗的可核验证据，不能据此记为画中画成功。控件自动隐藏后鼠标唤出问题也仍未解决。四项状态测试与原视频/画廊测试共 14 项通过，这不替代系统小窗和声音验收。Apple 的 [失败回调文档](https://developer.apple.com/documentation/avkit/avplayerviewcontrollerdelegate/playerviewcontroller(_:failedtostartpictureinpicturewitherror:)) 明确区分启动失败事件，SDK 27 头文件也提供该回调。


## 2026-10-15 长视频人工复查准备

用户撤回此前“移动鼠标后出现”的误选，并指出两秒视频不足以检查。该项仍未通过。已生成 60 秒、640×360、H.264 的本地静音测试视频（ffprobe 确认为 60.000000 秒），通过临时 Debug 菜单打开真实 URLGalleryView 和 MacVideoControlsButton，系统播放器显示 0:00 / −1:00，暂停在起点供用户操作。没有上传或发送素材。

构建日志 `/tmp/betterchat-hover-review-build.log` 成功。当前运行的验收二进制保留临时视频入口，源码中的临时菜单与资源引用已移除；下一次正常构建会移除。等待用户再次确认控件隐藏后的纯鼠标移动结果，不将准备完成算作交互通过。


用户随后确认：60 秒视频中，控件隐藏后移动鼠标可以正常唤出。此项按用户人工复验通过；不代表音频、画中画或 AirPlay 通过。用户新增要求：图片、视频均独立窗口并支持系统全屏。后续结果见 [媒体窗口复验](MEDIA_WINDOWS_UI_REVIEW.md)。
