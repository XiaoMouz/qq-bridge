# BetterChat for macOS 27

Swift 6 + SwiftUI + UIKit，通过 Apple 官方 Mac Catalyst 构建 macOS `.app`，使用 Mac idiom（`TARGETED_DEVICE_FAMILY = 2,6`），不是「Designed for iPad」运行模式。

## 架构与目录

```text
macos/
├── BetterChat/
│   ├── project.yml                      # XcodeGen 工程定义
│   ├── App/
│   │   ├── Application/                 # UIApplication / UIWindowScene、依赖装配、菜单
│   │   ├── Navigation/                  # 协调器、页面工厂、命令路由、宽窄窗口容器
│   │   ├── Core/Services/               # 可注入服务协议与 Session / 系统适配器
│   │   ├── DesignSystem/                # 统一尺寸、符号、原生控件与列表组件
│   │   └── Features/                    # 按功能组织 Views / ViewModels
│   │       ├── Authentication/          # 登录输入与请求状态
│   │       ├── Workspace/               # 侧栏分区、选中项与搜索草稿
│   │       ├── Conversations/           # 差量会话列表、聊天页面
│   │       ├── Search/                  # 搜索结果、取消与消息定位意图
│   │       ├── Contacts/                # 联系人列表、分组与刷新
│   │       ├── Settings/                # 设置选项与详情入口
│   │       ├── Downloads/               # 下载目录、授权和文件导出
│   │       └── Camera/                  # AVFoundation 拍照和录像
│   └── Resources/                       # Info.plist、沙盒和推送权限
├── tests/                               # 状态与文件检查
└── README.md
```

Apple 不要求特定的源文件目录名称；本工程按应用生命周期、功能、资源组织。独立 Mac 构建目标引用共享源码，不复制整套客户端：

- `ios/QQBridgeKit`：protobuf、ConnectRPC、GRDB、增量同步、发送和媒体缓存。
- `ios/QQBridge/App`：共用功能页面、聊天状态与消息渲染。排除 iOS 的应用入口及相机，分别由 Mac 实现。
- `ios/QQBridge/Shared`、`NotificationService`：共用通讯通知内容和通知扩展。
- `packages/protocol/proto/qqbridge/v1`：仍是唯一协议源，不另外定义 Mac HTTP 接口。

桌面页面通过 ViewModel 与可注入服务访问 QQBridgeKit；协调器负责路由与控制器生命周期。SyncEngine 负责差量追平及实时订阅，Sender 管理发件箱，MediaCache 按内容哈希缓存。列表使用差量数据源、按 ID 查找及只重配变化行；聊天仍使用现有可复用的 UICollectionView 单元格和历史窗口。分层边界与共享 iOS 页面的迁移范围见 [架构说明](ARCHITECTURE.md)。

## 功能与桌面适配

| 范围 | 实现方式 |
|---|---|
| 登录、恢复、退出、多设备 | 共用 Session；独立 Mac 钥匙串 service 与本地容器；登录平台为 `macos` |
| 会话、未读、草稿、置顶、免打扰、群助手 | UIKit sidebar + 共用 DialogRow / 同步协议；右键操作，选择状态保留 |
| 响应式导航 | 宽窗口双栏；低于 760 点切单栏列表/详情；系统侧栏按钮、⌃⌘S；群助手由列表汇总行进入，顶部“‹ 消息”返回 |
| 聊天、回复、撤回、转发、多选、回应、@、输入状态 | 共用 ChatScreen、ChatCollectionView 和完整消息组件 |
| 图片、动图、QQ 表情、视频、语音、文件、合并转发、卡片 | 共用媒体展示、播放、上传、拖放、粘贴与下载流程 |
| 语音消息、转文字、AI 语音 | 共用录音及 VoiceExtras |
| 拍照、录像 | Mac AVFoundation 摄像头界面，串行采集队列，按需申请摄像头 / 麦克风权限，最长 5 分钟 |
| 联系人、用户资料、群成员、公告、精华、群文件、群相册 | 左栏联系人列表、右栏资料；共用现有资料与群功能页面 |
| 全局 / 会话搜索、共享媒体、消息跳转 | 侧栏全局搜索；每个聊天右上角详情提供当前会话记录搜索，结果可定位对应消息 |
| 存储管理、策略、清理、归档、QQ 扫码登录 | 共用设置及管理页面 |
| 一对一语音呼入 / 呼出、群语音加入、静音 | 共用 CallManager、LiveKit、CallKit；Mac 用通话面板及横幅，真实通话待验收 |
| 通讯通知 | 独立 Mac 通知扩展；后端按设备平台选择 APNs topic |

Mac 图片编辑已按用户要求移除；iOS 图片编辑保留。这是明确的平台功能差异。

Mac 的图片与视频在独立窗口中查看，可与聊天并存；使用系统窗口按钮关闭、最小化或进入全屏。全屏时 Esc 优先退出全屏，普通窗口下 Esc 关闭当前媒体。逐项验证与边界见 [媒体窗口复验](MEDIA_WINDOWS_UI_REVIEW.md)。

这里的「共用」表示进入同一实现，不能代替真实账号下的逐项联调，也不会增加 iOS / 后端原本尚未实现的能力。

参考 iMessage 的视觉与 Telegram 的路由职责：宽窗口双栏，窄窗口在列表与详情之间导航。左栏底部是消息、联系人、设置三个 Liquid Glass 悬浮标签；搜索固定在左栏顶部，结果直接替换列表。设置选项和联系人列表留在左侧，右侧分别展示设置详情和联系人资料。聊天标题右侧信息按钮进入会话详细信息。切换分区保留当前聊天与草稿，设置也保留上次选中的详情。具体规则见 [界面设计](DESIGN.md)。

消息侧栏不再提供编写按钮或“会话操作”菜单。手动同步位于“设置 → 同步 → 立即同步”，原编写 / 同步快捷键一并移除。

Mac 拖入照片、视频或文件后先加入附件预览，与粘贴和文件选择保持一致；点击发送才提交，避免把未完成的文字草稿一起发出。iOS 保留原拖放行为。实际验收边界见 [拖放导入检查](DROP_IMPORT_REVIEW.md)。

原本支持下拉刷新的共享页面，在 Mac 导航栏提供“刷新”按钮，运行期间显示忙碌状态；复用各页面原有加载动作。iOS 保持下拉刷新。

使用 `UIApplicationDelegate` + `UIWindowSceneDelegate` 场景生命周期。Mac 失去焦点时保持同步；后台收到消息不自动标已读、不自动消费 @ 提醒；重新激活时更新已读状态。

| 快捷键 | 操作 |
|---|---|
| ⌘F | 聚焦当前分区侧栏搜索 |
| ⌘, | 设置 |
| ⌘1 / ⌘2 / ⌘3 | 消息 / 联系人 / 设置分区 |
| ⇧⌘U | 下一个未读会话 |
| Return | 发送（中文组字时先确认候选） |
| ⇧Return / ⌥Return | 换行 |
| ← / → | 图片查看器上一张 / 下一张 |
| Tab / ⇧Tab | 消息搜索框进入结果 / 从结果返回搜索框 |
| ↑ / ↓ | 侧栏结果之间选择并打开右侧内容 |
| Esc | 关闭媒体查看器；优先交给当前控件处理，无活动弹窗时可从其他标签返回消息 |

## 下载目录

文件默认保存到系统 `~/Downloads`。在“设置 → 下载”可选择其他文件夹或恢复默认，目录授权在重启后保留。聊天附件、共享媒体中的文件、群文件、存储浏览中的文件，以及图片查看器保存使用同一设置。图片保存按钮的右键菜单另提供“保存到相册”。

下载保留文件名，同名文件自动编号；重复打开已保存的文件会复用它，更改下载目录不搬动已有文件。下载完成前校验 SHA-256，新下载只暂存在临时目录，最终文件不加入 App 媒体缓存；旧版已有缓存可复用为下载来源。清理缓存不删除用户下载，群文件中的本机删除动作改为移到废纸篓。

沙盒使用 Downloads 读写 entitlement；自选目录通过系统目录选择器与安全作用域书签授权，遵循 [Apple 沙盒文件访问指南](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

文件处理检查覆盖名称清理、哈希校验、并发同名保存、目录与符号链接冲突，以及源文件缺失/目标类型错误时无残留（临时目录内测试，不操作用户下载）：

```sh
swiftc -parse-as-library macos/BetterChat/App/Features/Downloads/MacDownloadFiles.swift macos/tests/DownloadFilesCheck.swift -o /tmp/qqbridge-download-files-check
/tmp/qqbridge-download-files-check
```

群文件刷新选择检查（覆盖操作 ID 变化、顺序变化、删除和匹配歧义）：

```sh
swiftc -parse-as-library ios/QQBridge/App/GroupFileSelection.swift macos/tests/GroupFileSelectionCheck.swift -o /tmp/qqbridge-group-file-selection-check
/tmp/qqbridge-group-file-selection-check
```

手动同步任务检查（覆盖重复入口、失败重试、取消及旧任务晚返回）：

```sh
swiftc -swift-version 6 -parse-as-library macos/BetterChat/App/Application/MacManualSync.swift macos/tests/ManualSyncCheck.swift -o /tmp/qqbridge-manual-sync-check
/tmp/qqbridge-manual-sync-check
```

侧栏打开会话检查（覆盖重复点击、切换选择、退出后晚回包、失败重试及取消）：

```sh
swiftc -swift-version 6 -parse-as-library macos/BetterChat/App/Features/Search/ViewModels/MacChatOpenRequest.swift macos/tests/ChatOpenRequestCheck.swift -o /tmp/qqbridge-chat-open-check
/tmp/qqbridge-chat-open-check
```

## 构建

先运行不依赖真实账号的状态检查：`python3 macos/tests/run_state_checks.py`。实际应用 ViewModel 的 Catalyst 单元测试用 `xcodebuild … test`，完整命令与测试宿主隔离方式见 [测试说明](tests/README.md)。

需要 Xcode 27、macOS 27 和 XcodeGen。在仓库根目录运行：

```sh
./macos/build.sh
```

脚本生成工程并编译 Mac Catalyst 开发包，输出 `macos/.build-app/Build/Products/Debug-maccatalyst/BetterChat.app`。也可以打开 `macos/BetterChat/BetterChatMac.xcodeproj`，选择 **BetterChatMac / My Mac (Mac Catalyst)**。

本机仅预览登录界面可用 `MACOS_SIGNING=adhoc ./macos/build.sh`（兼容 `MACOS_ADHOC_SIGN=1`）。临时签名缺少 Catalyst 钥匙串所需的应用身份权限，不能用于登录、APNs 或分发验收；不要将其当作可登录的开发包。

登录联调请先在 Xcode → Settings → Accounts 登录开发者团队账号，然后运行：

```sh
MACOS_SIGNING=development ./macos/build.sh
```

该模式允许 Xcode 获取开发描述文件，使用团队签名和工程配置的沙盒 / Hardened Runtime 权限。仅安装开发证书不足以替代主应用和通知扩展的 Mac Catalyst 描述文件。

如果命令行报 `No Accounts`，而 Xcode 已显示团队，请在 Xcode 打开工程、选择 **My Mac (Mac Catalyst)** 并构建一次；按提示注册开发设备以生成本机描述文件。已有有效描述文件时，也可使用不带 `-allowProvisioningUpdates` 的 `xcodebuild` 命令。

团队签名运行、真机推送和发布需要为 `com.xiaomouz.betterchat.mac` 及其 `.NotificationService` 配置团队签名 / 描述文件。默认构建不访问开发者账户，不发布或公证。无签名构建不等同于可分发安装包。

服务端增加 `APNS_MACOS_TOPIC`（默认 `com.xiaomouz.betterchat.mac`）。原有 `APNS_TOPIC` 继续用于 iOS；Mac 普通通知和 VoIP 使用独立 topic。Mac 持续连接 Subscribe 不代表窗口在前台，因此来电仍走系统推送。2026-10-13 已确认无进行中通话后重启后端加载修复，健康检查通过；2026-10-14 Mac 普通与 VoIP 令牌已登记，普通验收推送已到达本机。已修复按旧未读计数提前清理新推送的问题；获准临时解除屏幕共享抑制后，系统记录横幅呈现，随后已恢复原设置；用户已确认实际看到通知并点击回到 Something；真实来电仍待验收，详见 [验收记录](ACCEPTANCE.md)。

通知清理按每个会话的已读消息序号判断，覆盖推送早于同步及部分已读的检查：

```sh
swiftc -parse-as-library ios/QQBridge/App/NotificationReadPolicy.swift macos/tests/NotificationReadCheck.swift -o /tmp/qqbridge-notification-read-check
/tmp/qqbridge-notification-read-check
```

## 发布（DMG、自动公证）

```sh
./macos/release.sh
```

一条命令完成：Release 归档 → Developer ID 签名并提交 Apple 公证 → 等公证完成、取回钉好票据的 app → 检查签名与 Gatekeeper → 打 DMG（拖到「应用程序」的布局）。版本号取 `BetterChat/project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，产物在 `macos/.release/BetterChat-<版本>-<构建号>/`，日志在其中的 `logs/`。

- **本机**：签名、公证走 Xcode 里登录的开发者账号（云端 Developer ID 证书，和 Organizer「直接分发」相同），不需要装证书。设 `NOTARY_PROFILE`（notarytool 钥匙串凭据）时 DMG 本身也公证。
- **GitHub Actions**（`.github/workflows/macos-release.yml`）：跑在 GitHub 的 `xcode-27` 预览机器上，推 `mac-v<版本>` 标签或手动触发；产出 DMG 作为构建产物，推标签时同时发 GitHub Release。签名和公证用 App Store Connect API 密钥（Admin 角色），在仓库 Secrets 里放 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8`（.p8 全文）；有密钥时 DMG 也会公证并钉票据。

产物只支持 Apple 芯片、macOS 27+。

## 验证

持续对齐工作的逐项范围和证据见 [能力对齐清单](PARITY.md)。群助手汇总行、快速回复浮层和手动同步已补齐实现；群助手与快速回复展开已于 2026-10-14 实机复验。

2026-10-14 按最新要求改为侧栏底部三个 Liquid Glass 分区，搜索结果直接替换左栏列表。已实测 ⌘1–⌘3、⌘F、设置左选右看、联系人资料、聊天草稿保留、搜索消息定位及深色双栏布局；重新打开当前会话也会恢复它所属的列表与选中行。

- macOS 27 / arm64 Mac Catalyst 应用及通知扩展编译。
- iOS Simulator 回归构建，检查共享代码的 iOS 分支。
- QQBridgeKit 15 项测试：同步、发件箱、媒体缓存。
- 后端 TypeScript 类型检查通过；完整测试 33 个文件、150 项通过，其中推送测试 18 项，包含 Mac / iOS topic 分流、平台传递、持续订阅时的来电、失败回退及群免打扰。
- 通过 Computer Use 完成真实登录、同步、搜索、联系人、群资料、媒体预览、设置、快捷键及重启恢复的基础验收；深色模式登录页和聊天页已检查。2026-10-14 桌面连接恢复后完成新标签、群助手及快速回复展开的复验；详细范围见验收记录。
- 2026-10-13 本机 ConnectRPC 接口可达；临时签名包登录出现 `KeychainError`。通过 Xcode 注册 Mac 开发设备、生成描述文件，并修正通知扩展多余的通讯通知 entitlement 后，开发者签名构建及 `codesign --verify --deep --strict` 已通过。详见 [验收记录](ACCEPTANCE.md)。
- 部分历史媒体缩略图失败已确认包含后端过期资源。实际发送、摄像头 / 麦克风、LiveKit / CallKit、通讯通知样式及签名分发仍需端到端验收；普通通知显示与点击已通过；完整结果和范围见 [验收记录](ACCEPTANCE.md)。

## 官方设计与开发依据

查阅日期：2026-10-13。本机：Xcode 27.0（27A266a），macOS 27.0.1。

- [Mac Catalyst](https://developer.apple.com/documentation/uikit/mac-catalyst)：UIKit 的 Mac 部署路径。
- [Choosing a user interface idiom for your Mac app](https://developer.apple.com/documentation/uikit/choosing-a-user-interface-idiom-for-your-mac-app)：Mac 控件尺寸与交互。
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)：窗口、菜单、键盘与指针。
- [UIKit updates](https://developer.apple.com/documentation/updates/uikit)：27 SDK 场景生命周期要求。
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)：Catalyst 窗口和控件行为。
- [Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)：优先由系统导航和控件提供材质，保持内容清晰。
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)：bundle ID 与普通 / VoIP topic 的对应关系。
- [Reporting an incoming call](https://developer.apple.com/documentation/callkit/cxprovider/reportnewincomingcall(with:update:completion:))：系统可能按勿扰或屏蔽策略过滤来电，不用 App 响铃绕过过滤。


录音授权与取消回归（直接运行共用 VoiceRecorder，通过延迟授权替身验证竞态，不请求系统权限、不录音）：

```bash
recording_sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-ios27.0-macabi \
  -sdk "$recording_sdk" -Fsystem "$recording_sdk/System/iOSSupport/System/Library/Frameworks" \
  ios/QQBridge/App/VoiceRecorder.swift macos/tests/VoiceRecordingStartCheck.swift \
  -o /tmp/qqbridge-recording-start-check
/tmp/qqbridge-recording-start-check
```

此检查不替代真实麦克风录制、音频输出或语音发送验收。


拖放中转文件回归（只读写随机生成的本机测试目录，不发消息）：

```bash
swiftc -swift-version 6 -parse-as-library ios/QQBridge/App/DroppedItem.swift \
  macos/tests/DroppedFileCheck.swift -o /tmp/qqbridge-drop-check
/tmp/qqbridge-drop-check
```

覆盖内容与名称保留、同名隔离、显式及自动清理、目录/符号链接/缺失文件拒绝及失败项保留。此检查不代替 Finder 跨窗口拖放的实际交互验收。


附件导入队列回归（延迟返回的模拟导入，不访问相册、不发送消息）：

```bash
swiftc -swift-version 6 -parse-as-library ios/QQBridge/App/AttachmentQueue.swift \
  macos/tests/AttachmentImportCheck.swift -o /tmp/qqbridge-import-check
/tmp/qqbridge-import-check
```

覆盖并发读取后的顺序提交、页面移交、独立草稿隔离、部分失败、错误保留与重试。相册选项和 Finder 文件的真实交付仍需单独验收。
