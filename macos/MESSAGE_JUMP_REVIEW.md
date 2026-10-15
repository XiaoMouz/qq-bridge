# 历史消息定位复核 · 2026-10-15

## 修复范围

原来的 `jump(to:)` 在每个调用方启动独立循环；旧任务的 defer 会清掉新目标，旧请求完成仍可能滚动。回到最新和页面离开不取消定位，路由延迟也不受管理。本地库错误被 try? 吞掉，列表刷新靠 50ms 轮询等待；列表慢和消息确实不存在没有可靠区分。

共享 `ChatMessageJump` 统一持有任务与 generation。新目标替换旧目标；详情/共享媒体返回的延迟在受管任务内；回到最新、发送后回底部、离开页面均取消。引用、@、搜索/媒体路由、调试定位使用同一入口。定位成功才触发滚动/高亮并允许 @ 标记已看；取消/失败不触发成功动作。

`LocalStore.historyTargetWindow` 在同一次数据库读取中返回可选区间下界、连续区间数量、目标之后数量及目标存在性。没有首屏区间时即使已有单条缓存也继续远端加载。目标进入连续区间后扩大窗口，等待实际 observeChat 列表推送（携带对应 limit，旧窗口的集合不能判定成功），5 秒兜底超时给出可重试提示，不冒充不存在。旧回包不改分页状态；重复页和区间重置停止当前定位并提供重试，页数采用实际本地窗口，避免重复消息使窗口不断膨胀。

定位失败在顶部显示独立原因、原目标重试及关闭提示，普通分页错误仍使用原入口；正在定位时 onAppear 不恢复另一路分页，底部新消息到达也保住待显示目标。

## 自动检查

- `ChatMessageJumpTests` 14 项，加已有分页 8 项；运行命令只选择这两个 suite。
- `HistoryTargetWindowTests` 两项，Swift 包全部 36 项通过：`/tmp/betterchat-message-jump-package.log`。
- 第一批定位 10 项与分页 8 项通过；新增区间被清空用例在旧对象文件下失败，之后重新构建最新修正验证。旧日志 `/tmp/betterchat-message-jump-final-tests.log` 保留失败，不能作为最终通过证据。

## 边界

不使用真实服务制造网络故障，不发送测试消息。模型控制时序测试不等同真实网络超时或同步重置的端到端验收；完整远端历史终点、超长历史性能和用户后续硬件/通话项目仍以 `PARITY.md` 为准。消息确定缺失的 @ 仍保留，避免未经用户操作丢掉未读提醒。


## 联合复核迭代

Opus 5.5 首轮方案审查指出 nil 区间、单次快照、分页恢复并发与目标等待等风险，按实际数据模型修正；第二轮发现缺失提示无法关闭、收窗后旧 rendered 集合可误判，已补关闭入口与列表 limit 匹配，以及两项回归。引用点击原本在单条预取完成后才登记定位，已改为立即进入受管任务，预览订阅仍保留。测试在 Mac 应用 target 执行共享模型；不是 iOS 实机测试。


## 最终结果

- 14 项定位 + 8 项分页共 **22 项通过**：`/tmp/betterchat-message-jump-final22-tests.log`；不是全量 117 项应用测试。
- 最后 UI 调整的两端构建通过：`/tmp/betterchat-message-jump-ui-build.log`、`/tmp/betterchat-message-jump-ui-ios.log`。
- 真实会话详情搜索与侧栏搜索均可定位 Something 的既有回复。Mac 引用已改标准 plain Button，实机点击会居中原消息并高亮，440 点窗口同样通过。iOS 保留触摸手势；定位失败后缺失的预览仍可重拉单条，不在预取完成后重新登记旧目标。
- 通过临时路由请求 Something 的不存在序号，在真实 ChatScreen 验证缺失提示、重试与关闭；已打开测试群的本地连续区间，此操作只读查询，没有发送。440 深浅色、1024 宽度通过，关闭后列表恢复，没有残留空白。
- 使用一次返回最新按钮回到现有最后记录；恢复跟随系统、1024×640 与空侧栏搜索/输入。
- 临时菜单及协调器方法均已删除。

截图：`/tmp/betterchat-ui-review/jump-search-reply-wide.png`、`jump-search-reply-440.png`、`jump-quote-highlight-440.png`、`jump-failure-wide.png`、`jump-failure-dark-clear-440.png`、`jump-failure-light-clear-440.png`、`jump-failure-dismissed-440.png`（同目录）。

Opus 最终代码复核 `/tmp/betterchat-opus-message-jump-round2.jsonl`，代码与截图复核 `/tmp/betterchat-opus-message-jump-ui.jsonl` 均无确定缺陷。其指出早期截图指针挡住重试按钮，主 agent 已移开指针补拍 clear 两张并检查按钮文字和底色可见。可选边界：取消定位后若引用预览仍缺，仍可能补读单条；这不会再次触发旧目标定位。未额外验证 iOS 真机触摸、真实网络中断、真实并发同步重置与超大历史性能。

清理后的最终 Mac 构建 `/tmp/betterchat-message-jump-clean-build.log` 通过，严格签名与差异检查通过，Package.resolved 未变。应用已重新启动至 Something，宽窗口、空搜索/输入，临时菜单无源码残留。
