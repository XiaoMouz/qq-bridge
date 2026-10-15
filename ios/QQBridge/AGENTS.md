# ios/QQBridge · iOS App「BetterChat」

Swift 6（严格并发）、SwiftUI + UIKit 聊天列表，iOS 26+。XcodeGen 生成工程（`project.yml` 是唯一来源，`BetterChat.xcodeproj` 由它生成）。Bundle `com.xiaomouz.betterchat`，scheme `BetterChat`，团队 L7V7ULL3VT。依赖 `../QQBridgeKit`、Lottie（超级表情）、LiveKit（通话）。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 路径 | 内容 |
|---|---|
| `App/QQBridgeApp.swift` / `AppModel.swift` / `RootView.swift` | 入口、全局状态（登录、连接、事件循环、通话）、标签页和全局浮层（横幅、提示、通话） |
| `App/DialogListView.swift` | 会话列表（「语音中」标记、置顶、群助手） |
| `App/ChatScreen.swift` / `ChatCollectionView.swift` / `ChatModels.swift` | 聊天页：倒置的 UICollectionView（最新在第 0 个）、横向拖动回复 / 拖语音进度、各种状态模型（成员、头像、语音播放、高亮…） |
| `App/ChatHistoryPagination.swift` / `ChatMessageJump.swift` / `ChatHistoryFailure.swift` | 历史分页、消息定位任务及显式重试；定位等列表观察通知，不轮询 UI |
| `App/MessageRow.swift` | 一行消息：气泡、排版块（文字、图片、语音、视频、文件、卡片…）、时间位置、回应、@ 徽章、小黄脸 |
| `App/ComposerField.swift` / `ComposerViews.swift` / `VoiceRecorder.swift` / `Attachments.swift` / `DroppedItem.swift` / `CameraPicker.swift` | 输入框（实体键盘回车发送、粘贴媒体）、录音生命周期、附件条、相机 |
| `App/ImageViewer.swift` / `MediaAndSearch.swift` / `MediaPopover.swift` / `MediaViews.swift` / `MediaReady.swift` | 看大图、视频播放、聊天记录、表情面板、转发选会话（`ChatPicker`）、媒体缓存显示、等服务端 `mediaReady` 推送 |
| `App/ChatExtras.swift` / `GroupContentViews.swift` / `GroupFilesView.swift` / `ProfileViews.swift` / `ContactsViews.swift` | 查找聊天记录、共享媒体、群公告 / 精华 / 文件 / 相册、资料页、联系人、@ 选人 |
| `App/SuperFace.swift` / `ReactionPicker.swift` / `QQFaceNames.swift` | 超级表情动画、表情回应面板、表情名字（`tools/qface-sync.py --ios` 生成，不手改） |
| `App/VoiceExtras.swift` / `VoicePlayer.swift` / `VoiceTranscripts.swift` / `AiVoiceSheet.swift` / `AiVoiceViewModel.swift` / `AiVoicePreview.swift` | 语音播放/进度/任务归属、转文字显示/缓存/请求状态、AI 语音页面/状态/试听生命周期、`CappedWidth` 布局 |
| `App/CallManager.swift` / `CallKitBridge.swift` | 通话：来电、接听、打出去、通话界面、横幅；CallKit + PushKit |
| `App/Push.swift` / `QuickReply.swift` | 推送注册、前台通知变 App 内横幅、快速回复 |
| `App/SettingsViews.swift` / `StorageBrowseViews.swift` / `QqLoginSheet.swift` / `LoginView.swift` / `OtherTabs.swift` | 设置、偏好、存储页、QQ 扫码、登录、搜索标签页 |
| `NotificationService/` | 通知扩展：把推送做成通讯通知（发送者头像） |
| `Shared/CommunicationContent.swift` | App 和通知扩展共用的通讯通知生成 |
| `Resources/QQFaces/` | 小黄脸静态图 `sNNN.png` |

## 构建与运行

```bash
xcodegen generate     # 改了 project.yml 或加 / 删了 Swift 文件
xcodebuild -project BetterChat.xcodeproj -scheme BetterChat -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
git checkout -- ../QQBridgeKit/Package.resolved   # 构建后还原
```

调试启动参数（`xcrun simctl launch booted com.xiaomouz.betterchat <参数>`）：
- `-debugJump <chatId>:<seq>`：打开会话后跳到那条消息
- `-debugCommNotify YES`：3 秒后发一条带头像的本地通知
- 环境变量 `QQB_SEARCH`：搜索页预填
- 打开某个会话：`xcrun simctl push booted com.xiaomouz.betterchat <json>`（json 带 `chatId`、`sender`）

## 约定

- **并发**：见 [lessons.md](../../docs/lessons.md) L1。`@MainActor` 的类、系统回调里先取 Sendable 的值。引入 LiveKit 的文件里 `Session` 会和 LiveKit 的重名，用 `BridgeSession`。
- **布局**：见 L4。聊天页的 body 修饰链已经很长，新的 sheet / 浮层写成单独的 `ViewModifier`（否则编译器推断超时）。
- **等服务端结果**：用 `MediaReady`（Subscribe 推送）或 `session.store.observeMessage` 订阅本地库，不轮询。
- **本地优先**：资料、头像先显示本地缓存再静默刷新；头像没有就 `AvatarBook.want(...)` 按需要。
- **模拟器测试**：见 L3。截图像素 ÷ 3 = 点；会话列表一直在变，用 `-debugJump` / 置顶会话 / `simctl push` 打开。模拟器没有相机、麦克风常报 -4010、收不到 VoIP 推送，这些要真机测。
- **发布**：只在用户要求时；升 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，`xcodebuild … -configuration Release -destination 'generic/platform=iOS' -archivePath ~/Library/Developer/Xcode/Archives/<日期>/BetterChat-<版本>-<构建号>.xcarchive -allowProvisioningUpdates archive`，然后 `open` 归档让用户在 Organizer 上传。新用到的系统能力要加 `Info.plist` 权限说明（审核会查第三方库引用的 API，例如 LiveKit 要相机说明）。
