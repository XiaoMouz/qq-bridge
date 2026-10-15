# Finder 拖放未出现预览（2026-10-15，未通过）

用户亲自将 Finder「betterchat-drag-acceptance」的「拖放测试.txt」拖入 Something 后，反馈没有附件预览。这是实际失败反馈，不能以自动化工具自身无法完成拖动为由排除。

Opus 5.5 只读诊断确认：文件选择和拖放最终共用附件队列；当前仍不能区分 UIKit/SwiftUI 目标未收到拖放，还是 Transferable 在进入导入回调前加载失败。`.item` 表示匹配只是候选原因，尚未取得真实 Finder provider 类型，不按猜测调整。

## 当前诊断构建

- `MacDropDiagnostics.swift`、ChatCollectionView、ChatScreen、DroppedItem 仅在 Catalyst DEBUG 记录：UIKit canHandle 的项数和类型、SwiftUI targeted/perform、Transferable 文件回调。只观察的 UIKit delegate 返回 false，不接收文件。
- 日志 subsystem `com.xiaomouz.betterchat.mac`，category `FileDrop`；不记录文件路径、文件名或内容。
- 2026-10-15 10:25:31 已确认运行中的 Something 页面记录 `UIKit probe installed`。
- 已请用户再拖入同一个 TXT，不点发送。等待此次事件证据；当前不能声称修复。
- 定位后应移除临时诊断类与插桩；iOS 条件编译不进入这些代码。

Mac 构建 `/tmp/betterchat-drop-diagnostics-final-build.log` 及严格签名检查通过。iOS 构建 `/tmp/betterchat-login-share-final-ios-build.log` 通过；Package.resolved 没有差异。临时隔离登录菜单已移除。

Claude 继续实现探针的调用遭遇会话额度限制，未修改代码；以上探针由 Codex 实现。

## 后续：系统提供器复现并修复文件 URL 转换

未收到用户新的 Finder 结果前，用真实 `NSItemProvider` 与 `CoreTransferable` 做隔离检查，发现一个独立且确定的导入错误：

- `NSItemProvider(contentsOf:)` 注册 `public.plain-text / public.file-url / public.url`，原实现能读取 TXT 字节。
- `NSItemProvider(object: NSURL)` 只注册 `public.file-url / public.url`，原实现却成功导入一个名为“文件URL”的描述文件，内容不是原始 TXT。失败证据：`/tmp/betterchat-drop-provider-tests.log`，两项中一项失败（内容及文件名两处断言）。

Mac `DroppedItem` 现在优先通过 URL 的 Transferable 表示解析地址，再沿用 `DroppedFile` 的安全作用域、普通文件校验与临时副本；仅提供内容时仍使用 FileRepresentation。iOS 不增加这个分支。空的 Mac 投放回调补显式错误提示，避免静默返回。

修复后 `MacDroppedProviderTests` 四项通过：`/tmp/betterchat-drop-provider-fixed-tests.log`。覆盖混合类型文件提供器、仅 URL、仅内容、目录与网页 URL 拒绝。全部直接调用系统提供器，不伪造完成回调；素材只在测试临时目录，不发送、不读取用户文件。这些测试没有经过 Finder 的拖放会话，不能用它们宣布最初的“没有预览”已经解决。

已移除只观察的 `UIDropInteraction` 探针和相关安装代码，避免新增交互影响最终系统路由；只保留 DEBUG 的 SwiftUI targeted/perform 与 Transferable URL/file 阶段日志。仍待用户用最终构建真实拖入。

最终 Mac `/tmp/betterchat-drop-url-final-build.log`、iOS `/tmp/betterchat-drop-url-ios-build.log` 均构建成功，严格签名、差异检查通过，Package.resolved 无变化。旧应用确认退出后重新启动，新构建已显示 Something 最新消息和空输入；Finder 实测仍未取得新结果。

## 用户复验仍失败：改用消息列表原生接收协议

用户随后明确反馈“没有出现蒙层”“已拖入诊断版，仍没有预览”。当次查询最近 30 分钟的 FileDrop 日志无任何事件；这支持故障发生在导入之前，但不能单凭日志缺失确定系统实际命中了哪个视图。

Mac 现在把 `MacChatFileDropReceiver` 直接设置为真实 `ChatCollectionController` 的 `UICollectionView.dropDelegate`，移除 Mac 外层 SwiftUI `dropDestination`，不再让两个接收入口竞争。按 [Apple 的列表拖放指南](https://developer.apple.com/documentation/uikit/supporting-drag-and-drop-in-collection-views) 使用复制提议及进入/退出/结束回调驱动蒙层。没有增加覆盖聊天区、阻挡滚动和点击的透明视图。iOS 继续使用原 SwiftUI 拖放与发送逻辑。

`MacDroppedProviders` 在投放回调内立即向全部提供器发起读取，再按原顺序导入。松手时捕获附件队列，切换会话不会改变归属；成功项进入待发送预览，失败项显示错误，绝不因拖放自动发送。沿用已实测的文件 URL 优先解析、安全作用域与临时副本生命周期。

新增 `MacNativeFileDropTests` 三项检查真实聊天列表的 delegate 安装/持有、混合提供器的成功和失败、切换草稿时的归属与待发送状态；它们与原四项提供器测试均不是 Finder 端到端拖放。真实 Finder 结果仍待新版复验，不能将修复候选标为通过。

最终验证：`/tmp/betterchat-native-drop-tests.log` 7 项/2 组通过；`/tmp/betterchat-native-drop-final-build.log` 与 `/tmp/betterchat-native-drop-ios-build.log` 均构建成功，严格签名及 `git diff --check` 通过，Package.resolved 无变化。11:24 重新启动正常签名构建，进程 25217，Something 消息列表与空输入框可见、输入可获得焦点；截图 `/tmp/betterchat-ui-review/native-file-drop-ready.png`。测试宿主 24220 / 24965 的 perform/import 日志不能当作用户拖放证据。已请求用户在这个版本复验一次，尚未收到结果。

## Finder 真实接收通过，蒙层外观待调整

用户确认原生接收版已出现添加附件提示，并加入待发送。运行进程 25217 于 11:31、11:32 的日志也记录 `canHandle=true`、`targeted=true/false`、`perform count=1`、`import finished attachments=1 failures=0`。真实 Finder 提供器为 `public.plain-text` 与 `com.apple.finder.node`，实际走 FileRepresentation。这次 TXT 接收与预览已通过；不能扩展为所有媒体来源通过。

用户指出蒙层存在 UI 问题，并表示将在下一条消息具体说明。等待说明后调整；临时视觉预览菜单已从源码移除，未在运行中的应用启用。

## 蒙层边界与居中修复（用户截图复现）

用户截图明确显示：提示按整窗居中、右侧聊天区内偏左；虚线框左侧被裁掉，底边覆盖输入区。用户随后明确接受模糊背景，所以保留 ultraThinMaterial。

Mac 增加独立 `MacFileDropHint`，不再使用 iOS 蒙层的 `ignoresSafeArea`，按消息列表可用区域居中。模糊背景和虚线边框放在背景层，四边统一内缩 12 点，并裁切在本区域内；输入框及待发送附件不被覆盖。iOS 蒙层及拖放接收/导入逻辑保持原有行为。

通过临时菜单在实际 Something 的 ChatScreen 上固定显示同一个生产蒙层，检查 1024×640 与 440×480、深浅色、空草稿及已有 TXT 附件。宽窗口提示位于右栏中央，四边框完整；最小窗口加入附件后，蒙层随列表可用高度缩小，卡片和输入区完整露出；隐藏后正常恢复。素材使用既有本地布局测试 TXT，验收后已移除，没有发送。此入口只切换目标提示，不伪造系统拖放或文件导入成功。

截图：`/tmp/betterchat-ui-review/drop-overlay-wide-dark.png`、`drop-overlay-compact-dark.png`、`drop-overlay-compact-light.png`、`drop-overlay-compact-attachment.png`、`drop-overlay-wide-light.png`、`drop-overlay-wide-attachment.png`。临时菜单已移除，窗口恢复 1024×640、跟随系统外观和空草稿。

最终 Mac 构建 `/tmp/betterchat-drop-overlay-final-build.log` 和 iOS 构建 `/tmp/betterchat-drop-overlay-ios-build.log` 成功；严格签名与差异检查通过，Package.resolved 无变化。正常构建已重新启动（进程 39596），显示 Something 空草稿，无强制蒙层、无本次测试附件。

## 激活窗口后的自动化对照复验（2026-10-15 12:35）

针对此前输入框的工具焦点问题，再次用截图位置实际点击激活 Finder，然后将现有测试 TXT 从图标位置拖到同窗口的测试文件夹。结果仍只有选中项变为文件夹；文件系统确认原位置 TXT 存在、目标文件夹内不存在。这排除了“只要激活窗口工具拖放就会恢复”的假设，不据此判断 BetterChat 接收失败，也不继续重复跨窗口无效拖动。

已在 Finder 打开既有 `BetterChat-media-acceptance.nGeZZm`，仅选中 PNG、MP4、GIF 三项，向用户请求一次实际混合拖入 Something、不点击发送的检查。当前三种格式的真实 Finder 结果待回复；文件选择器混合导入与 Photos 图片／视频的已有成功证据不替代它。此轮没有改代码或移动测试文件，应用保留 Something 空输入供用户操作。
