# 独立图片窗口操作复验（2026-10-15）

## 实机结果

- 从 Something 的既有静态验收图片打开独立窗口（5/6），保存按钮显示保存到 `/Users/xiaomouz/Downloads`。实际新增文件 `aa01cec4873062b51d3dd975a86ce2a00dd1afa2fe6f526ce9099a6a6d2bd897.jpg`，10,356 字节，SHA-256 与文件名中的媒体哈希一致。未改下载设置；文件留在 Downloads。
- 分享按钮打开系统 `ShareSheet.Popover`，但面板内容为“Unlock Mac to continue with Siri request”。已退出面板，没有选择分享目的地或发送；这不是完整分享成功证据，也没有将系统提示归因于 App 的分享实现。
- 图片转发选择页成功打开。用辅助功能设置搜索词 Something，只保留该会话；不匹配关键词显示“没有找到”。鼠标取消回到原图片，重新打开和再次取消正常。没有选择目标、转发图片或创建会话。
- 普通文字键入没有改变搜索词，改用可设置的搜索控件后筛选生效；不将辅助功能设置值等同于真实键盘输入验收。

截图：`/tmp/betterchat-ui-review/image-window-save.png`、`image-window-share-system-lock.png`、`image-window-forward-filter.png`。

## Mac 转发选择的请求生命周期

源码发现 `ChatPicker` 对尚无会话的好友/群使用非结构化 Task，完成后直接调用 onPick；取消表单不会取消这个任务，因而可能在用户取消之后继续转发。本轮没有用真实账号制造这条发送竞态。

Mac 接入已有的 `MacChatOpenRequest`：鼠标取消及 Esc 立即使请求失效，页面离开兜底取消，改变搜索词也取消旧选择。迟到成功/失败不能交付 onPick 或弹旧错误；使用 scene + peerID 区分好友/群的等待状态。消息、图片和群文件转发共用此页面，因此一并获得保护。iOS 保留原来的 Task 与行为。

生产请求类的 `ChatOpenRequestCheck` 检查通过，覆盖重复点击、替换选择、取消后晚回包、失败重试、取消收尾。这个检查证明请求隔离本身，不代替真实页面在慢速服务器响应时的交互验收。

新的真实恢复消息授权和系统分享解锁确认仍等待用户答复；本轮不执行依赖答复的发送或服务停启。

## 最终构建与新版本复验

- Mac 构建 `/tmp/betterchat-image-actions-build.log`、iOS 构建 `/tmp/betterchat-image-actions-ios.log` 均成功；Mac 严格签名校验及 `git diff --check` 通过，`QQBridgeKit/Package.resolved` 未变。
- 退出旧 Mac 进程并确认对应可执行文件不再运行后，打开最终构建。再次从 Something 打开既有测试图片，转发页筛选 Something 正常。搜索框聚焦时第一次 Esc 清除并结束搜索，第二次 Esc 关闭表单，原图仍为 5/6；再次打开和鼠标取消正常。
- 新版本重开截图：`/tmp/betterchat-ui-review/image-window-forward-reopen.png`。最后关闭图片窗口，回到 Something 最新消息、空输入框。没有发送或转发新消息。

## 系统分享的 Esc 修复

后续实际复验发现 Esc 从系统分享穿透到媒体关闭。现已修复并验证：分享期间方向键不换图，Esc 仅关闭分享；全屏按层级先关闭分享、再退出全屏、最后关闭图片窗口。系统解锁限制仍在，不计为文件分享成功。详见 [媒体键盘复验](MEDIA_KEYBOARD_REVIEW.md)。
