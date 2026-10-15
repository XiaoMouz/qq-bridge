# 资料卡与最小窗口补充验收（2026-10-14）

## 分工与结论

Codex 使用 Computer Use 进行实机操作、截图与构建。Claude Code（Opus 5.5、auto）独立核对了原生资料卡的源码，建议从窗口根控制器呈现，并禁止表单自适应；这一建议经 Codex 实测有效。Claude 的最终截图复核因会话额度用尽没有执行，因此下面的最终截图与交互结论均由 Codex 负责，不能标为双人终验。

## 发现与修复

原 SwiftUI 资料卡的「完成」按钮在 440×480 和宽窗口中点击均不能关闭，Esc 可以。给按钮显式绑定关闭回调、更换 toolbar placement、使用 form sizing，单独都没有解决。初版 UIKit anchor 直接呈现时，资料卡又出现工具栏缺失，关闭后主窗口残留「资料 / 关闭」。因此推翻旧清单中对当前资料卡点击关闭的通过结论。

最终由 `MacProfileCardPresenter` 从窗口根控制器呈现独立的 UIKit formSheet；卡片明确 regular 尺寸类、禁止自适应成其他呈现方式，并有自己的 Esc 命令。首选尺寸为 400×440，资料列表仍可滚动。原页面保留选择状态，鼠标关闭、Esc、系统关闭及外部 dismiss 都清除该选择；资料页成功打开会话后也主动收尾。共享调用点统一使用 `profileCard`，iOS 分支保留 SwiftUI sheet 与 medium / large detents。

这证明最终组合修复有效；没有通过运行时层级日志单独证明是哪一个 UIKit 自适应因素导致旧实现失效，不把诊断推测写成系统事实。

## 实测结果

| 范围 | 结果与证据 |
|---|---|
| 440×480 深色 → 群资料 → 本人资料卡 | 卡片自己的标题与关闭按钮可见；鼠标关闭回到原群资料，主窗口标题正确。`profile-native-card-440.png`、`profile-native-close-return-440.png` |
| 重复打开同一资料卡 → Esc | 选择能够再次触发呈现；Esc 只关闭卡片，群资料与成员位置仍在。最终构建再次执行这一流程通过。 |
| 1024×640 浅色 → 同一卡片 | 卡片工具栏可见；列表可滚动；鼠标关闭回到群资料。`profile-native-card-wide-light.png` |
| 440×480 回复条 | 对既有验收 TXT 选择回复，显示引用及取消入口；取消后清空，没有发送。`min-reply-file-dark.png` |
| 440×480 两个本地 TXT 附件 | 长文件名布局可见；移除第一项后第二项序号更新，再移除第二项，恢复空输入。`min-two-attachments-dark.png`。没有上传或发送。 |
| 群资料子页面 | 群文件列表、群公告 / 群精华 / 群相册空状态可见，使用页面返回按钮回到群资料。`min-group-{files,notices,essence,albums}-dark.png`。未执行群资料写操作。 |
| 底部三分区 | 实际点击联系人、设置、消息，内容和选中态均切换。 |
| 搜索无结果 | 440×480 浅色下，长搜索词换行完整，提示位于悬浮栏上方。`f5-search-empty-440-light.png` |

所有截图位于 `/tmp/betterchat-ui-review/`。旧诊断截图 `min-profile-close-fixed.png` / `min-profile-close-return.png` 的文件名不代表修复成功：它们记录的是失败尝试，不能用作通过证据。

## 校验与边界

- 最终 Mac 与 iOS 模拟器构建均成功：`/tmp/betterchat-profile-final-mac.log`、`/tmp/betterchat-profile-final-ios.log`。
- Mac 严格签名校验、差异格式检查通过；`ios/QQBridgeKit/Package.resolved` 未变化。
- 「发消息」后的主动收尾、外部路由 dismiss 的状态清理已实现并核对源码，尚未用真实其他联系人操作验证；没有因此向其他人建会话或发消息。
- 群公告内号码资料卡、消息头像资料卡共用同一呈现器，但这轮只实测群成员入口；不把复用等同于所有入口通过。
- 还未覆盖全部资料写操作、无障碍模式、完整硬件与通话；整体 iOS 对齐仍以 [PARITY.md](PARITY.md) 为准。
- 已恢复 1024×640、跟随系统外观、Something 会话。搜索和输入为空，无附件或弹窗残留。最终界面：`f5-profile-final-workspace.png`。


## 后续：真实 UIKit 生命周期回归检查（2026-10-14）

新增 `BetterChat/Tests/MacProfileCardTests.swift`，在隔离的 Catalyst 测试宿主里使用真实 UIWindow、UIViewController 与生产 `MacProfileCardAnchor`，内容只是本地测试文字，不加载账号或 Session。

修复前实际复现：先显示 A、选择 B，等 A 的关闭动画开始后销毁 anchor，旧 dismiss completion 会继续安排 B 的呈现。`teardownDuringReplacementNeverPresentsAgain` 失败，日志 `/tmp/betterchat-profile-lifecycle-before.log`。这会导致原页面已移走却仍出现资料卡。

现增加明确的 teardown 终态：拒绝后续 update / schedule，取消并释放任务，清除待呈现内容和 ID，晚到的关闭 completion 不能重新打开。五项 UIKit 检查通过：

1. 尚未执行呈现时清空选择，不弹卡片。
2. 原页面清空选择后关闭，再次选择同一人可以重新打开。
3. 子控制器关闭由窗口根控制器呈现的卡片，owner 只收到一次关闭，之后可再次打开。
4. 替换选择先关闭旧卡片，再打开新卡片，旧关闭事件不误清新选择。
5. 替换动画期间销毁呈现器，不会被旧 completion 重新弹出。

整体 12 项应用测试（5 项资料卡 + 7 项搜索）通过：`/tmp/betterchat-profile-lifecycle-final.log`。进一步将外部 dismiss 用例改为从子控制器调用，针对协调器实际层级复核，5 项资料卡检查通过：`/tmp/betterchat-profile-lifecycle-routing.log`。UIKit 27 SDK 的 UIViewController.h 说明 presentedViewController 包括最近祖先呈现的控制器，检查也证实了这一点，因此没有为错误的层级假设改写协调器。

Mac 构建及严格签名通过，Package.resolved 未变化；本轮没有修改 iOS 源码，未重复 iOS 构建。普通应用已重新打开 Something，搜索/输入为空。后端仍不可达，未将隔离测试冒称实际通知跳转、其他联系人发消息或网络恢复的端到端验收。


## 后续：快速回复嵌套入口复验（2026-10-14）

Claude 在静态复核时推断“快速回复占用了主窗口根控制器的 presentedViewController，因此资料卡被 guard 拒绝”。Codex 没有据此修改生产代码，先补真实 UIKit 表单检查，再操作实际 SwiftUI 快速回复。原有代码均通过，该推断已撤回。不能假定 Catalyst 中任意 anchor 的 `view.window.rootViewController` 都是主工作区的根控制器。具体 window 身份没有打印，文档不将其解释当作运行证据。

新增两项测试：

- 嵌套表单内的 anchor 打开资料卡；关闭资料卡保留父表单；同一个 ID 再次打开新的资料卡。
- 与 anchor 无关的表单不会接收底层页面的资料卡请求。

`/tmp/betterchat-nested-profile-baseline.log` 显示原有生产代码下 7 项资料卡检查全部通过。初版测试夹具使用空 UIViewController 并等待呈现 completion 时未完成，已中止该测试进程；最终夹具使用 UIHostingController，并有界等待真实转场状态，不能将夹具的问题算成应用失败。

真实操作只在 Something 的已有消息上查看头像资料：主窗口 1024×640，右键快速回复 → 历史头像 → 资料；鼠标关闭返回快速回复，同头像重开后 Esc 也返回快速回复。第三次打开点击 @，卡片关闭，输入框出现结构化提及；已全选删除，未发送。父窗口改为 440×480 后重复头像打开与 Esc 返回同样通过。Catalyst 表单自身有独立尺寸，本轮快速回复截图为 470×440、资料卡为 400×440，不将父窗口尺寸写成表单尺寸。

截图 `/tmp/betterchat-ui-review/`：

- `quick-reply-profile-open.png`：资料卡实际打开。
- `quick-reply-profile-return.png`：关闭后仍在快速回复，输入为空。
- `quick-reply-profile-mention-draft.png`：@ 仅插入草稿，之后已清空。
- `quick-reply-profile-from-440-window.png`：最小父窗口下的资料卡。
- `quick-reply-profile-final-workspace.png`：第一次复验后的正常主会话，无浮层和草稿；最小窗口补测后同样恢复宽窗口。

Claude 已独立阅读前三张截图、生产代码和新增测试，明确撤回先前缺陷判断。复核日志 `/tmp/betterchat-nested-profile-review.jsonl`；其将“宽父窗口”列作未测，Codex 实际首轮即为 1024×640，这里按操作记录纠正。未验证的仍是点击“发消息”、外部通知/路由切走时的真实收尾，以及浅色嵌套路径。没有创建新会话、改提醒设置、联系其他人或发送消息。生产呈现器未改，仅增加回归测试与更新验收记录。


## 2026-10-15 真实资料跳转补验

通过 Something 群资料中的成员资料卡，点击“发消息”进入已存在的 BOT 私聊：卡片收起，工作区切到消息分区，侧栏选中 BOT，右侧标题与历史一致。随后从联系人搜索同一好友，进入详情并缩至 440×480，点击“发消息”正确进入同一私聊；原生 Back 返回消息列表，选中行仍是 BOT。本轮只打开既有会话，没有给该联系人发送消息，没有调用通话，也未操作另一套机器人服务或文件。

截图 `/tmp/betterchat-ui-review/profile-open-chat-wide.png` 和 `contact-open-chat-narrow.png`。此前待测的这两条在线成功路由现已补证；快速回复资料卡的发消息路由、请求中关闭及外部通知打断仍不因此视为通过。生产资料卡实现没有修改。


## 2026-10-15 快速回复资料跳转与跨会话草稿修复

真实复现了此前未覆盖的问题：Something 为主会话，在快速回复输入文字，经历史头像的资料卡点击“发消息”进入既有 BOT 私聊。两层弹窗正确关闭、目标私聊输入为空，但返回 Something 后草稿丢失。原因是 MacChatCoordinator 只持有当前一份 MacChatDraft，切换会话重建；快速回复的关闭回调也只接收当前会话。

协调器现按 chatID 保存固定的 MacChatDraft 对象，切换时仅重建聊天页面；浮层关闭即使晚于主会话切换，也写回原会话。保持固定的可观察状态对象，让已有页面也能收到迟到的草稿更新。没有改共享 Composer 或 iOS。MacPageFactory 增加两方法的窄协议，测试使用空 UIViewController 和内存工作区服务，直接运行真实协调器，不初始化账号。

五项专项检查通过（`/tmp/betterchat-chat-drafts-tests.log`）：跨会话保留文字、结构化 @、引用与附件；迟到关闭回传且不污染目标会话；未在主窗口打开的会话接收草稿及展开两种回调顺序；清空与工作区释放；切走后待完成附件导入仍交付原会话。不是全量测试。

新构建实际重复上述头像 → 资料 → 既有私聊路径，返回 Something 后恢复完整输入，再打开快速回复仍显示同样内容。截图 `/tmp/betterchat-ui-review/quick-profile-draft-restored.png`。重新打开成功也说明本次外部关闭未留下阻止再呈现的 sheet 状态；没有依据静态推断增加 UIKit 层级改动。测试输入后来已通过真实键盘全选删除，主会话确认恢复空输入、语音图标，没有发送或调用通话。

本次 Mac 构建随专项测试完成，严格签名与差异检查通过；Package.resolved 未变。仅改 Mac 文件，未重复无改动的 iOS 构建。草稿仍是当前工作区内存状态，不提供跨重启恢复；暂不驱逐未发送草稿，含图片的草稿会占用内存，直到用户移除或工作区释放。真实请求中关闭、外部通知打断及发送中的路由仍未验收。

Claude Code（Opus 5.5、auto）最终只读复核未发现阻塞问题，并撤回其初次报告中“快速回复起点必然为 nil”的错误前提；起始主会话实际是 Something。完整草稿以跳转前后的辅助功能 Value 核对，截图只作可见状态佐证。详见 [Opus 草稿路由复核](OPUS_DRAFT_ROUTE_REVIEW.md)。

## 后续：资料页打开会话的取消隔离（2026-10-15）

Mac 的「发消息」改用已有 `MacChatOpenRequest`，显示等待状态并防重复点击；鼠标关闭卡片或资料页消失时取消请求，迟到响应不得重新改变主窗口路由。iOS 保留原实现。生产请求检查覆盖重复、取消、迟到结果与重试并通过；真实慢响应期间关闭、外部通知打断仍未实测，不把模型检查等同端到端通过。

最终正常构建中，从 Something 群成员列表打开两个资料卡并用鼠标关闭；从既有好友卡「发消息」打开原有私聊，卡片关闭。联系人精确搜索后打开同一好友详情，「删除好友」只打开确认框，点取消后仍显示好友关系、选择保留；再点「发消息」正常返回该私聊。没有删除、发消息或发起通话。截图 `profile-request-existing-chat.png` 位于临时验收目录。

Mac 构建 `/tmp/betterchat-profile-open-final-build.log`、iOS 构建 `/tmp/betterchat-profile-open-ios.log` 均成功，Mac 严格签名、差异检查通过，Package.resolved 未变。恢复 Something 与空搜索/输入。该轮实机与代码检查由 Codex 执行。
