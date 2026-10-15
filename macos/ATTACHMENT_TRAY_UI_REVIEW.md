# Mac 附件栏界面复验（2026-10-15）

本轮使用生产 AttachmentTray / AttachmentOutboxObserver 和内存 LocalStore 构造失败、排队、上传中及待发送附件；未调用发送接口。上半部的测试按钮是临时验收壳，不是产品界面。验收后删除临时源码和菜单。

## 修正

- Mac 拆出 MacAttachmentTile / MacAttachmentTray，iOS 保留原附件卡片。
- 移除按钮使用无背景的圆形图标、24 点点击区域，不再带默认矩形按钮底。
- 文件状态使用固定的图标区域，不覆盖文件名；长文件名中间截断，保留扩展名，悬停可读全文。
- 上传显示确定进度条与百分比；文件失败使用红色图标，缩略图上状态使用白色。排队有独立时钟及说明。
- 移除排队附件的提示明确“不取消已提交的发送”；卡片总体提示不再覆盖按钮自己的提示。
- 宽度不足时显示左右翻动按钮，调用系统 ScrollPosition 移动，保留一张卡片的重叠；到边界禁用对应按钮，宽度足够时不显示。保留原生横向滚动，隐藏叠在底边的滚动条，动画尊重减少动态效果。

## 实机证据

- 440×480 深浅色：长文件名、短名、上传百分比、失败/排队标志及移除按钮可辨，无图标与文件名重叠。
- 受控初始六项中移除排队附件变五项；失败提示可关闭；开始重试后变时钟；确认 sent 后仅对应项移除。删除内存排队记录会变为“发送记录已不可用，可重试”，仍可移除。
- 十项附件下，点击下一屏能到完整末项，右按钮禁用；移除末项后十变九且滚动范围收尾；点击前一屏回到开头，左按钮禁用。
- 继续从末尾移除至四项后，左右按钮消失，内容回到左侧，无空白残留（`attachment-final-shrink-four.png`）。
- 1024×640 能完整显示十项，左右按钮不出现。缩略图包含失败、40% 上传、排队和待发送视频四种状态。
- 通过辅助功能树确认完整文件名、上传百分比和错误原因；排队移除提示独立保留。
- 最终无临时入口的构建中，从实际 Something 聊天页的系统文件选择器导入本地 `second.txt`，宽窄窗口的卡片与输入框无重叠；点击移除后附件栏消失，没有发送，恢复 1024×640、跟随系统、空搜索/输入。截图为 `attachment-final-real-chat-440.png`。

截图位于本机 `/tmp/betterchat-ui-review/`：

- `attachment-states-before-440.png`：修正前。
- `attachment-final-light-start-440.png`：窄窗口文件状态。
- `attachment-final-dark-end-440.png`、`attachment-final-light-end-440.png`：末端缩略图及状态。
- `attachment-final-light-wide.png`：宽窗口十项附件。

## 边界

这轮界面验收不代表真实断网、回包丢失、强退和上传端到端验收。自动化横向滚轮未产生可见变化，不能据此断言原生触控板滚动失效；左右按钮已实际点击验证。上传过程中仍沿用现有规则隐藏移除按钮，没有新增取消上传能力。

Opus 5.5 使用 Claude Code auto 模式联合复核源码和截图，详见 [复核记录](OPUS_ATTACHMENT_TILE_REVIEW.md)。

## 构建与清理

Mac 最终构建 `/tmp/betterchat-attachment-ui-final-build.log` 与 iOS 模拟器构建 `/tmp/betterchat-attachment-tray-ios.log` 均成功。严格签名和 `git diff --check` 通过，Package.resolved 未变。临时内存验收源码与菜单已移除；本轮只调整 Mac 展示，没有再次运行此前已通过的发送状态测试，不将旧测试计作本轮新结果。
