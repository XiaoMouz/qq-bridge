# 聊天历史分页复验 · 2026-10-15

## 本轮修改

`ChatHistoryPagination` 管理窗口大小、加载任务、终点与错误；`SessionChatHistoryPagingService` 接现有本地库/同步引擎。失败后停止自动请求，重试保留窗口；本地读取失败不会当作历史到头。离开取消，返回恢复被中断的请求，generation 隔离迟到成功/失败。先检查可展开的本地记录，再判断服务端终点。

共享 `ChatScreen` 接入模型，`ChatHistoryFailure` 用顶部安全区显示错误原因和重试，避免遮住消息。返回最新且不再加载时延迟收窗。跳转未加载消息前取消滚动分页；已加载目标不打断分页。iOS 同时获得可靠性修复，图片编辑等手机功能保留。

## 验证证据

- 八项 `ChatHistoryPaginationTests` 通过：`/tmp/betterchat-history-pagination-final-tests.log`。不是一次全量 103 项执行。
- 清理临时入口后的 Mac 构建通过：`/tmp/betterchat-history-pagination-clean-build.log`；严格签名、`git diff --check` 通过，Package.resolved 未变。重新打开应用后恢复宽窗口 Something，搜索和输入为空。
- iOS 模拟器构建通过：`/tmp/betterchat-history-pagination-final-ios.log`。
- 受控内存服务首请求超时、重试成功；440×480 深浅色的错误原因和重试完整，60→90 条成功后提示消失，再失败仍保留 90 条；1024×640 无重叠。使用生产模型/失败组件，普通 List 宿主，不能替代倒置聊天列表的故障场景。
- 真实 Something 浏览由 10 月滚到 8 月，缩为 440×480 后历史仍在，单击向下按钮回到 10 月最新记录。只读历史，没有发送消息或操作旧消息。
- 临时 `HistoryReviewFixture` 和菜单移除；生成工程已更新。

截图位于本机临时目录（不会作为项目资源）：

- `/tmp/betterchat-ui-review/history-failure-dark-440.png`
- `/tmp/betterchat-ui-review/history-retry-dark-440.png`
- `/tmp/betterchat-ui-review/history-failure-light-440.png`
- `/tmp/betterchat-ui-review/history-failure-light-wide.png`
- `/tmp/betterchat-ui-review/history-real-august-wide.png`
- `/tmp/betterchat-ui-review/history-real-august-440.png`
- `/tmp/betterchat-ui-review/history-real-return-latest-440.png`

## Opus 5.5 联合复核

Claude Code 使用 Opus 5.5 与 auto 权限模式，只读复核代码和四张受控截图。首轮指出的返回恢复、加载完成后补收窗、本地未展示内容被终点挡住均已修正并纳入测试；最终无阻断问题。代码结果 `/tmp/betterchat-opus-history-pagination-final.jsonl`，截图结果 `/tmp/betterchat-opus-history-ui-final.jsonl`。测试和构建由主 agent 执行，不能归为 Opus 实测。

## 仍未覆盖

- 没有用真实服务制造分页超时，也没有读尽整个群的远端历史。
- 受控截图没有覆盖请求长期悬挂时的真实聊天加载指示器。
- 失败条重试时收起、再次失败时出现，会改变顶部占位；Opus 认为可进一步保留加载占位以平滑布局。宽屏失败条按钮距文字较远、浅色说明偏淡，列为非阻断视觉建议。
- 原有多个历史跳转同时发起的状态归属、跳转失败提示和重复页窗口计数仍需单独检查；本轮不宣称它们已通过。
- 完整功能对齐继续以 `PARITY.md` 为准。
