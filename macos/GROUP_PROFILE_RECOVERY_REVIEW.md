# 群资料与成员加载恢复（2026-10-15）

## 实现与协作

Claude Code Opus 5.5（auto）负责 GroupInfoView 的 Mac 状态行和工具栏；Codex 实现 MacGroupResource / MacGroupProfileViewModel 及 GroupMembers 的 Mac 请求状态，完成测试和实机操作。

- 群资料与成员各自报告失败并提供重试；刷新失败保留旧资料和成员，只有成功的空响应才显示「成员 0 / 没有成员」。首次未加载完成时只显示「成员」。成员搜索无匹配提供说明。
- 顶部「刷新群资料」同时刷新资料和成员，与侧栏刷新联系人区别命名。资料与成员请求分别合并重复操作。
- 成员缓存由聊天和资料共用，资料消失不取消成员请求。强制刷新会取代仍在读取服务端缓存的普通请求，旧结果隔离。
- 资料消失取消请求；如果打断的是用户主动刷新，返回后继续刷新并保留旧值。已加载且没有中断时返回不重拉。
- Mac 使用指定 chatID 的数据库观察，不受会话列表数量上限影响。iOS 保留原 GroupInfoView / GroupMembers 行为。

Opus 第二轮源码复核确认内部 Observable 对象可经外层计算属性被 SwiftUI 追踪，没有发现状态归属缺陷，并指出强制刷新优先级与中断刷新恢复两处问题；Codex 已修复并补回归。原始日志 `/tmp/betterchat-opus-group-profile-ui.jsonl`、`/tmp/betterchat-opus-group-profile-check.jsonl`。

## 受控界面检查

在生产 GroupInfoView 的联系人入口临时注入响应，不停服务、不改网络、不写群资料。440×480 深色下，首次成员失败显示「成员」和错误/重试；点击重试后得到两条成员；再刷新失败保留两条；成功空响应清空并显示「没有成员」。首轮截图 `group-profile-first-error-440.png`、`group-members-first-error-440.png`、`group-members-refresh-error-440.png` 中仍是系统原始错误文案，后续改为中文网络/超时提示，不能把旧图当作最终错误文案证据。`group-members-empty-440.png` 为成功空列表布局。

更新后的错误文案截图：`group-profile-final-error-440.png`、`group-profile-final-error-wide-light.png`、`group-members-final-error-440.png`、`group-members-final-error-440-light.png`。这次从聊天详情入口注入失败，原有 4 名真实成员仍在；切回真实响应并刷新，资料恢复 4/200 人。Opus 实际读图复核无确定布局缺陷，浅色图鼠标遮挡了几个字，深色图完整可见。故障注入不能证明真实网络断开恢复。

## 最终验证

- 9 项 MacGroupResourceTests 通过：首次失败/成功空区分、刷新失败保留与防重、切群迟到成功/失败、取消返回、成员失败重试与 lookup、成员刷新失败到成功空、强制刷新升级、资料刷新中断后返回。日志 `/tmp/betterchat-group-profile-final-tests.log`。测试首次编译因 memberCount 使用 Int32 而不是 UInt32 失败，已修正后重跑通过；最终日志对应通过版本。
- 移除临时响应注入及菜单，重新生成工程；最终 Mac 构建 `/tmp/betterchat-group-profile-clean-build.log`、iOS 构建 `/tmp/betterchat-group-profile-ios.log` 成功。Mac 严格签名与差异检查通过，Package.resolved 未变。应用测试声明共 186 项，本轮仅运行新增 9 项，不宣称全量通过。
- 退出旧进程后在最终正常构建验证聊天标题及联系人两个入口，都能显示真实群资料并点击刷新。聊天详情搜索不存在的成员显示无匹配提示，清空恢复原列表；群公告进入/返回保留成员 4，成员资料卡可鼠标关闭。真实无匹配截图 `group-members-real-no-match.png`。
- 最终 Opus 代码与四张截图复核没有确定缺陷：`/tmp/betterchat-opus-group-profile-final.jsonl`。运行和截图由 Codex 执行，Opus 只读复核。
- 已恢复 1024×640、跟随系统、Something 最新消息、空搜索/输入及联系人好友分段。没有发送、删除或修改群设置。实际网络故障、在真实慢请求中进子页等仍不由这些检查代替。
