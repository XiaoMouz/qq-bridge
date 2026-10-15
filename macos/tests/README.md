# macOS 状态检查

最近一次完整应用执行结果为 217 项／36 组通过（2026-10-15，`/tmp/betterchat-release-mac-tests.log`）；七组独立状态与文件检查也全部通过（`/tmp/betterchat-release-state-checks.log`）。下文各历史数量仅对应当时版本，不代表当前总数。

两端共用的状态及媒体测试现在位于 `ios/QQBridge/Tests/Shared`，两个工程各自编译同一批测试，验证实际平台分支。iOS 另有手机标注画布测试，完整 93 项／12 组通过（`/tmp/betterchat-release-ios-tests-pass.log`）。Mac 独有测试仍在 `BetterChat/Tests`。

2026-10-15 群文件移动目录选择接入共用加载模型与原生表单。六项 `MacGroupListTests` + 八项 `MacProfileCardTests` 共 14 项通过（`/tmp/betterchat-folder-picker-native-tests.log`），没有新增测试声明。真实取消失败与修复、受控重试 UI 的边界见 [目录选择复验](../GROUP_FOLDER_PICKER_REVIEW.md)。

在仓库根目录执行：

```sh
python3 macos/tests/run_state_checks.py
```

统一入口编译实际生产源码，运行登录、手动同步、联系人打开请求、下载文件保存、下载设置、群文件选择恢复和通知已读清理七组检查。它不读取账号凭据、不连接真实服务、不发送消息；文件检查只操作新建的临时目录。需要 Xcode 的 Swift 6 工具链。

源码目录迁移后仍按唯一文件名定位；缺失或出现重复实现会直接失败。编译产物自动清理，不产生新的 Swift 包依赖或派生数据缓存。

UIKit / AVFoundation、附件导入与 QQBridgeKit 的专门检查仍按 [验收记录](../ACCEPTANCE.md) 和 [开发说明](../README.md) 执行。这个入口不等于完整 UI、网络或硬件测试。


## 应用 ViewModel 测试（Mac Catalyst）

`BetterChat/Tests/MacSidebarSearchTests.swift` 通过 `@testable import BetterChat` 测试真实搜索 ViewModel，使用假服务和 continuation 控制返回顺序。覆盖联系人打开失败的正确重试、已有结果/选择保留、搜索与打开同时失败、重复重试、过期查询与过期打开的隔离、清空查询后旧重试失效、取消打开后行加载状态收尾。

```sh
xcodegen generate --spec macos/BetterChat/project.yml
xcodebuild -project macos/BetterChat/BetterChatMac.xcodeproj -scheme BetterChatMac \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath macos/.build-app test
```

`BetterChatMacTests` 是 XcodeGen 定义的单元测试 target；测试 action 单独设置 `BETTERCHAT_STATE_TESTS=1`。DEBUG 宿主在这个模式下不初始化工作区、不恢复账号、不注册推送、不访问用户库，仅建立空窗口供 UIKit 运行。普通 Run action 没有该变量，Release 不启用此路径。测试资料、联系人和请求均为内存假数据，没有复制生产 ViewModel，也没有替换它的实现逻辑。

测试不连接真实后端，不能代替真实断网/恢复或错误提示的视觉验收。项目规格参考 [XcodeGen ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)；测试宿主路径明确使用实际产品名 BetterChat，而非 target 名 BetterChatMac。


资料卡生命周期检查 `BetterChat/Tests/MacProfileCardTests.swift` 使用真实 UIKit 窗口与生产呈现器，检查清空选择、重复打开、外部 dismiss、替换选择和替换期间销毁。只显示测试文字，不依赖 Session 或网络。测试有界等待实际 UIKit 转场状态，达到状态后立即继续；超时记录失败。

只运行这一组时，在上述 xcodebuild 命令末尾加 `-only-testing:BetterChatMacTests/MacProfileCardTests`。完整应用测试现为 173 项（7 项搜索 + 8 项资料卡/共用表单 + 5 项视频生命周期 + 4 项 Mac 画中画状态 + 3 项导航容器 + 5 项 URL 画廊播放器 + 3 项图片布局 + 6 项群相册分页 + 6 项群列表恢复 + 5 项媒体窗口 + 7 项会话内搜索 + 6 项精华/媒体订阅恢复 + 5 项群文件加载恢复 + 7 项共享媒体分页 + 5 项会话草稿 + 9 项附件发送 + 7 项附件发件箱观察 + 8 项聊天历史分页 + 14 项消息定位 + 12 项 AI 语音 + 7 项语音转文字 + 17 项语音播放 + 6 项存储分页 + 3 项存储文件打开 + 4 项存储引用会话 + 4 项存储统计）；独立的七组命令行状态/文件检查仍是另一组入口，不混计测试数量。

视频生命周期检查 `BetterChat/Tests/VideoPreviewTests.swift` 测试共享的 `VideoPreviewModel` 和真实 AVPlayer：关闭后链接晚返回、任务取消、旧加载不覆盖新播放器、播放器尚未挂载时关闭，以及解析失败后重试。使用 continuation 控制顺序和不存在的本地 URL，不访问网络；不能据此判断解码、声音输出或画中画通过。

2026-10-15 按用户要求移除 Mac 图片编辑及其画布测试；iOS 图片编辑保留。以下历史测试数量是对应当时版本，不代表当前一次全量运行。

资料卡另补嵌套快速回复表单中打开/关闭/重开，以及无关表单不能接收底层资料请求。7 项资料卡专项检查通过；新增两项后没有重复运行未改动的其他测试组，上一轮全量 22 项结果仍保留各自范围。

导航容器检查 `BetterChat/Tests/MacAdaptiveSplitTests.swift` 在真实 UIKit 窗口中呈现透明全屏覆盖和 formSheet，验证宽→窄、窄→宽在覆盖退出后补布局，以及普通表单不阻止主窗口适配。3 项专项检查通过（`/tmp/betterchat-modal-title-tests.log`）；SwiftUI 覆盖回调接线另由实际图片查看器/标注入口验证。本轮没有将此前各专项结果合并宣称为一次 27 项全量运行。

URL 画廊检查 `BetterChat/Tests/URLGalleryPlaybackTests.swift` 使用真实 AVPlayer 和不存在的本地 URL，覆盖同页保持实例、切图释放、切视频替换、同页链接更换、重复关闭与重开；5 项专项测试通过（`/tmp/betterchat-url-gallery-tests.log`），不是一次全量 32 项运行。受控媒体的真实解码、翻页和宽窄返回证据及未覆盖项见 [画廊复验](../URL_GALLERY_UI_REVIEW.md)。

图片布局检查 `BetterChat/Tests/ImageLayoutTests.swift` 实例化生产 CenteringScrollView 并执行 UIKit 布局：普通竖照在矮、宽、窄窗口均完整可见，横图保持比例，真正长截图仍可滚动。3 项专项测试通过（`/tmp/betterchat-gallery-portrait-tests-final.log`），不包含用户缩放后调整窗口或 iOS 触摸手势；本轮不是一次全量 35 项运行。


Mac 画中画状态检查 `BetterChat/Tests/MacVideoPictureInPictureTests.swift` 直接调用真实 VideoPlayback 的 AVKit 代理回调，覆盖启动失败后关闭、旧播放器迟到开始/停止、内嵌切系统呈现后旧回调隔离。四项在修复前全部失败（`/tmp/betterchat-pip-regression-before.log`）；修复后与视频/画廊生命周期合计 14 项通过（`/tmp/betterchat-pip-regression-after.log`）。使用无媒体的 AVPlayer 和隔离宿主，不联网；此证据验证状态所有权，不代表系统画中画窗口、声音或返回界面已端到端通过。

群相册分页检查 `BetterChat/Tests/MacAlbumMediaTests.swift` 使用真实生产 ViewModel 和可控 continuation 服务，覆盖空的中间页继续加载、首屏失败重试、后续失败保留照片并从同一游标重试、页内/跨页去重、取消后的迟到回包隔离、重复请求以及重复游标防循环。运行参数为 `-only-testing:BetterChatMacTests/MacAlbumMediaTests`，不连接真实账号。UI 的窄窗口重试与照片保留另见 [群内容复验](../GROUP_CONTENT_UI_REVIEW.md)，不将六项专项执行宣称为一次全量四十项运行。

群列表恢复检查 `BetterChat/Tests/MacGroupListTests.swift` 使用公告/相册共用的真实 `MacGroupListViewModel`，覆盖首屏失败显式重试、成功空列表、刷新失败保留内容、重复请求合并、取消后迟到成功/失败隔离、从详情返回不重复加载。六项通过（`/tmp/betterchat-group-list-tests.log`），命令参数 `-only-testing:BetterChatMacTests/MacGroupListTests`；不连接真实服务。本轮不是一次全量 46 项测试。


媒体窗口检查 `BetterChat/Tests/MacMediaWindowTests.swift` 使用真实窗口请求路由与可控激活回调，覆盖并发请求内容隔离、一次性交付、激活失败重试、迟到失败隔离、退出账号前取消待连接请求、每窗资源独立释放，以及两个真实 VideoPreviewModel 的控制器互不替换。与视频 / 画中画 / 画廊生命周期合计 19 项通过（`/tmp/betterchat-media-windows-tests.log`）；不连接真实账号，也不等同系统窗口交互验收。实际多窗口和全屏结果见 [媒体窗口复验](../MEDIA_WINDOWS_UI_REVIEW.md)。

## 会话内搜索（2026-10-15）

`MacChatHistoryTests` 新增五项：查询与结果限制当前会话、先后查询乱序、清空后迟到结果、失败重试、离开后迟到失败及无效会话 ID 不退化为全局搜索。专项日志 `/tmp/betterchat-chat-history-tests.log`，五项通过；不是全量运行。

## 群精华与媒体订阅恢复（2026-10-15）

六项 `MacGroupEssenceTests` 覆盖首屏失败后重试并重新订阅、刷新与媒体通知交错只补拉一次、刷新失败保留旧行、离开期间媒体完成后返回重新读取、旧请求失效、终态媒体不订阅，以及真实 MediaReady.Watch 缓冲/等待取消和适配器任务取消。返回重读测试在旧实现下失败（`/tmp/betterchat-essence-tests-before.log`），修复后与六项群列表检查共 12 项通过（`/tmp/betterchat-essence-tests-after.log`）。没有用这些测试代替真实网络或图片 UI 验收。


## 群文件加载恢复（2026-10-15）

`MacGroupFilesTests` 五项测试通过（`/tmp/betterchat-group-files-recovery-tests.log`）：首次失败与空结果重试、刷新失败保留目录/文件/选择、QQ 操作 ID 更新后选择映射、请求期间改变选择与歧义元数据不误匹配、重复加载合并、取消后的迟到成功和失败隔离。使用内存服务、真实 ViewModel 与共享 GroupFileSelection，不访问群文件或执行下载/修改。不是一次 67 项全量运行。


## 共享媒体查询和分页（2026-10-15）

`MacSharedMediaTests` 七项生产模型测试通过（`/tmp/betterchat-shared-media-tests.log`）。覆盖图片/文件切换后的迟到结果、排序变化后的旧错误、最新排序的 seq 与其他排序的 offset、首屏失败重试、空中间页继续、后续失败保留内容和游标、重试期间不自动循环、同媒体更新而不同 ord 保留、重复游标拒绝、取消后返回重新加载。内存服务不连接账号，不代表真实网络或 UI 已完成验收；本轮不是 74 项全量执行。


## 跨会话草稿（2026-10-15）

`MacChatDraftTests` 使用生产 MacChatCoordinator、空控制器工厂和内存工作区服务，五项通过（`/tmp/betterchat-chat-drafts-tests.log`）。覆盖文字 / 结构化 @ / 回复 / 附件跨会话保留、不污染目标会话、快速回复关闭迟到、未打开会话的草稿、展开回调顺序、同会话不重建页面、清空与工作区释放、切走后附件导入完成。命令参数 `-only-testing:BetterChatMacTests/MacChatDraftTests`。不连接账号，不发送消息；真实头像资料跳转另见资料卡复验。本轮不是 79 项全量运行。


## 附件发送重试（2026-10-15）

`AttachmentSendingTests` 六项检查（含文件/视频参数化场景）直接运行共享 AttachmentSending、真实 Sender 和内存 LocalStore。覆盖回包丢失后的稳定请求、发件箱与附件条交叉重试、上传失败后重试、原引用与当前批次引用区分、迟到进度不覆盖失败、相同媒体重新选择两次及已移除附件不发送。与五项 MacChatDraftTests 合计 11 项通过（`/tmp/betterchat-attachment-retry-final-tests.log`），不是 85 项全量执行；不连接真实账号。iOS 模拟器构建通过。


## 附件条与发件箱状态（2026-10-15）

`AttachmentOutboxTests` 七项测试使用生产 AttachmentSending、内存 LocalStore 的真实 GRDB 观察，覆盖状态推进/成功移除、取消后补读快照、独立错误归属、活动批次不被旧失败覆盖、迟到 RPC 失败隔离、空结果/跨会话隔离，以及真实 UIWindow / UIHostingController 中 AttachmentOutboxObserver 对批次完成与新增附件的订阅更新。与附件发送、会话草稿共 18 项通过（`/tmp/betterchat-attachment-outbox-final-tests.log`），不是 92 项全量运行。

QQBridgeKit 新增 SenderIdentityTests 四项，覆盖同 ID 重试保留首次时间、已成功记录免网络请求、同键不同内容拒绝及服务端已接收 pending/sending 不重新发起尝试；包内全部 34 项通过（`/tmp/betterchat-outbox-state-final-package.log`）。不连接真实账号。


## 上传进度回调生命周期（2026-10-15）

AttachmentSendingTests 新增三项：上传失败后跨草稿重试的旧进度隔离、上传已完成/准备好的发送重试不被迟到进度覆盖、上传服务保留回调不持有已结束草稿。前两项在原实现下复现四处断言失败（`/tmp/betterchat-upload-progress-before.log`）；修正后附件发送九项、发件箱观察七项、草稿五项共 **21 项**通过（`/tmp/betterchat-upload-progress-after.log`）。测试使用 continuation 控制上传和提交边界，短暂让出 MainActor 后检查迟到任务没有写入；不连接真实服务，不替代实网断连或强退验收。iOS 构建 `/tmp/betterchat-upload-progress-ios.log` 通过。本轮不是一次 95 项全量运行。


## 聊天历史分页恢复（2026-10-15）

`ChatHistoryPaginationTests` 八项生产模型测试通过（`/tmp/betterchat-history-pagination-final-tests.log`），运行参数 `-only-testing:BetterChatMacTests/ChatHistoryPaginationTests`。覆盖先展开本地窗口、失败保留窗口并显式重试、读取本地失败不判为终点、重复请求合并、取消/返回恢复与旧回包隔离、到达新消息与收窗、跳转取消，以及服务端到头后仍可展开未显示的本地历史。使用 continuation 控制请求，不访问真实账号。本轮不是 103 项全量运行；iOS 构建日志 `/tmp/betterchat-history-pagination-final-ios.log`。受控错误界面和真实历史浏览见 [历史分页复验](../HISTORY_PAGINATION_UI_REVIEW.md)。


## 历史消息定位（2026-10-15）

`ChatMessageJumpTests` 14 项生产模型检查覆盖本地目标等待列表推送、旧远端成功/失败不覆盖新目标、取消等待、调用方取消、延迟路由替换/取消、本地读取失败和缺失重试、多页连接单独缓存的目标、按实际窗口计数、重复页/终点、列表更新超时、冷启动无区间与同步重置区间。另覆盖收窗后旧列表不可用于成功判定、缺失提示可关闭；与八项分页检查合计 22 项；不连接账号，真实页面接线另外实测。源码共有 117 项应用测试，不代表本轮全量执行。

`HistoryTargetWindowTests` 两项使用真实内存 LocalStore，检查 nil 区间与单条缓存区分、连续区间/seq 空洞/跨会话隔离；Swift 包全部 36 项通过（`/tmp/betterchat-message-jump-package.log`）。

最终 22 项通过：`/tmp/betterchat-message-jump-final22-tests.log`；最终 UI 改动 iOS 构建通过：`/tmp/betterchat-message-jump-ui-ios.log`。真实搜索、引用按钮和失败关闭截图见 [消息定位复核](../MESSAGE_JUMP_REVIEW.md)。


## AI 语音与转文字缓存（2026-10-15）

`AiVoiceTests` 十二项覆盖角色加载失败重试、草稿保留、分类和可见角色一致、空分类禁用、重复请求合并、加载旧回包隔离、同一个模型离开后发送结果交付、失败保留输入、播放结束/失败/卡顿清理、旧播放器通知隔离、音频配置失败，以及不存在的本地文件触发真实 AVPlayer status 失败。多数播放器场景用空 composition 与手工通知，不能代表真实声音或完整播放验收。

`VoiceTranscriptsTests` 七项直接运行共享生产模型和独立 UserDefaults suite。覆盖缓存/空文本收起恢复及重启持久隐藏、失败不自动循环与手动重试、重复请求合并、取消后迟到成功/失败隔离、自动识别设置和手动隐藏、不同会话相同 seq 隔离、旧格式和 500 条上限、超过 500 个隐藏 key 时与磁盘缓存一致裁剪。

两组共 **19 项**通过：`/tmp/betterchat-voice-final19-tests.log`。命令追加 `-only-testing:BetterChatMacTests/AiVoiceTests -only-testing:BetterChatMacTests/VoiceTranscriptsTests`。不联网、不读取账号、不发送消息；不是 136 项全量运行。受控 UI 证据见 [转文字复验](../VOICE_TRANSCRIPTS_REVIEW.md) 与 [AI 语音复验](../AI_VOICE_REVIEW.md)。


## 语音播放生命周期与拖动（2026-10-15）

`VoicePlayerTests` 十六项通过（`/tmp/betterchat-voice-player-final16-tests.log`），追加参数 `-only-testing:BetterChatMacTests/VoicePlayerTests`。覆盖同媒体停/重开时迟到来源成功和失败、离开后取消加载、失败重试、正常结束/失败清理、旧通知隔离、连续拖动与跨播放的 seek 完成隔离、取消拖动、加载超时与迟到成功、音频配置失败、真实 AVPlayer 初始文件失败、重复 sha 的消息身份与波形隔离、不同页面播放互斥、音频中断后重开、错误查询的 Observation 跟踪、卡顿不强制结束、临时副本半文件恢复、录音权限等待占用与取消。部分测试使用参数化情形，16 指测试声明数。

播放器检查不配置真实音频、不播放声音；空 composition/无效本地文件、手工通知用于验证状态，不能代表实际解码或硬件。`VoiceRecordingStartCheck` 原有授权与取消检查另已通过。生产消息列表下的本地静音 WAV 解码、鼠标拖动与深浅色恢复见 [语音播放复验](../VOICE_PLAYBACK_REVIEW.md)。不是 164 项全量执行。

最终补充 AI 试听与聊天语音双向互斥（含尚在下载的聊天语音）：17 项播放测试与 12 项 AI 语音测试共 29 项通过，日志 `/tmp/betterchat-voice-player-clean-tests.log`。没有配置音频或发网络请求。

会话内搜索补游标续页、失败保留与重试、去重、重复游标和旧分页隔离；7 项通过，日志 `/tmp/betterchat-navigation-pagination-tests.log`。以上数量为当前测试声明，不表示全量 164 项本轮执行。

## 存储明细分页与文件预览

`MacStorageItemsTests` 6 项、`MacStorageFileTests` 3 项覆盖并发分页防重、失败保留与重试、offset/去重、取消/迟到结果、下载和临时预览清理边界。首轮 9 项通过；Kit 全部 37 项通过，新增 325 份同尺寸缓存的分页检查。生产页面受控故障与真实入口的范围见 [存储明细复验](../STORAGE_ITEMS_REVIEW.md)。

## 存储引用与通用原生表单（2026-10-15）

`MacStorageReferencesTests` 新增 4 项，`MacProfileCardTests` 增至 8 项（字符串媒体标识关闭/重开/Escape）。最终与存储分页、文件打开合计 21 项通过，日志 `/tmp/betterchat-storage-references-native-tests.log`。全部测试声明共 169 项；修改前 164 项全量通过，本轮最终跑 21 项相关回归。真实本机、服务器入口及关闭修复见 [引用会话复验](../STORAGE_REFERENCES_REVIEW.md)。

## 会话存储统计（2026-10-15）

`MacStorageSummaryTests` 新增 4 项，通过日志 `/tmp/betterchat-storage-summary-tests.log`。覆盖首次失败/显式重试/空结果、重复请求合并、详情刷新失败保留与零占用替换、取消后重开及迟到成功/失败隔离、分类返回保留快照。内存响应不连接账号；当前共有 173 项测试声明，本轮只运行新增 4 项。真实列表、详情、分类返回及深浅色图表检查见 [存储统计复验](../STORAGE_SUMMARIES_REVIEW.md)。

2026-10-15 联系人群资料：新增 `MacContactGroupTests` 四项（失败重试、超时迟到成功/失败、离开返回隔离）单独运行通过，应用测试声明总数 177；本轮未全量运行 177 项。Swift 包全量 38 项通过，包括指定会话观察。证据见 `../CONTACT_GROUP_RECOVERY_REVIEW.md`。

2026-10-15 群资料与成员恢复：新增 `MacGroupResourceTests` 9 项单独运行通过，当前应用测试声明总数 186；本轮没有全量运行。覆盖失败保留、成功空、请求取消/切群、成员强制刷新升级及资料刷新中断恢复。最终 Mac/iOS 构建通过，证据见 `../GROUP_PROFILE_RECOVERY_REVIEW.md`。


## 全量回归与登录布局（2026-10-15）

完整应用测试 **186 项、28 个套件**通过：`/tmp/betterchat-full-regression-186.log`。随后新增 `MacLoginLayoutTests` 两项单独通过：`/tmp/betterchat-login-layout-before.log`。当前测试声明总数 **188**，不合并宣称为一次全量运行。

登录检查使用生产 UIKit 控制器、假认证服务和隔离偏好，覆盖长错误提示、440×428 最小内容区域以及 1024×588 → 440×428 → 600×588 调整。检查表单可达、横向边界、标签换行及输入框高度；不恢复账号、不连接服务、不实际登录。既有实现通过，未因此修改生产登录代码。仅运行这组可追加 `-only-testing:BetterChatMacTests/MacLoginLayoutTests`。

### 服务器预设与连通性（2026-10-15，已运行）

登录页补齐 iOS `LoginView` 的服务器预设菜单、「实际连接」地址和无需登录的 `/healthz` 检查。地址补全通过 `MacServerReachabilityService.resolve` 注入，生产实现直接调用 `AppModel.normalize`；健康请求只在生产装配的 `MacHTTPServerReachabilityService` 里发出（不带凭据、5 秒超时），检查与测试一律用不联网的替身。

- `LoginViewModelCheck` 追加：400ms 防抖只查最后一个地址、旧请求迟到不覆盖、地址不对不请求、200 / 非 200 / 出错三种状态与重试、预设立即检查、离开页面后迟到结果不回写、页面释放不被挂起请求保活。`run_state_checks.py` 输入不变（协议与 ViewModel 同在原两份源码里）。
- `MacLoginLayoutTests` 新增一项：超长服务器地址与长连通错误、长登录错误同时出现时，在 440×428 与 1024×588 下控件可达、地址按字符换行、预设菜单与「重新检查」按钮存在；宽屏表单不超过 360 并居中。已有两项改为排除隐藏控件后再检查可达性。


## 会话列表操作恢复（2026-10-15）

新增四项 `MacDialogsTests`，专项通过日志 `/tmp/betterchat-dialog-recovery-tests.log`。覆盖失败身份与队列、观察停止保留/显式重试/角标回调、同会话顺序且跨会话不阻塞、模型释放后等待写入不提交。使用假服务和 continuation，不联网。当前共 192 项测试声明，不是本轮全量执行。真实生产控制器的受控 UI 验证见 [会话操作复验](../DIALOG_OPERATIONS_REVIEW.md)。

## 媒体弹层键盘（2026-10-15）

`MacMediaKeyboardTests` 一项专项通过，覆盖真实 UIKit 表单呈现时旧按键回调不穿透，以及关闭后恢复四种动作。日志 `/tmp/betterchat-media-keyboard-tests.log`，运行筛选 `-only-testing:BetterChatMacTests/MacMediaKeyboardTests`。当前共 193 项声明，不合并宣称为一次全量运行。系统分享与全屏的实机验证见 [媒体键盘复验](../MEDIA_KEYBOARD_REVIEW.md)。

登录最终五项（另增密码编辑后健康刷新保留、APIError 文案）与图片分享五项合计 **10 项通过**：`/tmp/betterchat-login-share-tests.log`。独立 `LoginViewModelCheck` 也通过。当前 201 项声明，不代表一次全量运行；图片测试与真实 UI 范围见 [分享复验](../IMAGE_SHARE_REVIEW.md)。

## 回应者名单（2026-10-15）

`MacReactionUsersTests` 四项专项通过，日志 `/tmp/betterchat-reaction-users-model-tests.log`，筛选 `-only-testing:BetterChatMacTests/MacReactionUsersTests`。使用可控服务与 continuation 验证真实生产模型的失败重试/空成功、旧表情迟到成功和失败、刷新失败保留缓存、关闭重开和释放取消。当前应用测试声明总数 205，不代表一次全量运行。正常界面入口与实际名单检查见 [回应与提及复验](../REACTION_MENTION_REVIEW.md)。

## 系统文件提供器（2026-10-15）

`MacDroppedProviderTests` 四项通过（`/tmp/betterchat-drop-provider-fixed-tests.log`），筛选 `-only-testing:BetterChatMacTests/MacDroppedProviderTests`。测试真实 NSItemProvider/CoreTransferable 的含文件内容、仅文件 URL、仅内容及不支持 URL 导入。修复前仅 URL 情况实际得到“文件URL”描述文件而非 TXT，文件名及字节断言失败；修复后通过。当前共 209 项声明，不是全量执行。这不能替代 Finder 手动拖放，详见 [拖放诊断](../FILE_DROP_REVIEW.md)。

### Mac 原生拖放接收

`MacNativeFileDropTests` 新增三项，与 `MacDroppedProviderTests` 一起共七项通过：`/tmp/betterchat-native-drop-tests.log`。验证实际聊天列表安装并持有原生 drop delegate、真实文件提供器的部分成功和错误、异步导入期间切换草稿的归属与未发送状态。当前应用测试声明总数 212，不代表全量执行。Finder 拖放仍需用户确认，测试不模拟成功的系统拖动。
