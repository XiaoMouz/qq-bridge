# Mac 聊天头像与回复操作复验（2026-10-15）

## 证据与改动

Something 的真实群消息可见发送者头像，但旧版辅助功能树没有对应的具名按钮。`SenderAvatar` 原来只使用 `onTapGesture` / `onLongPressGesture`。

与 Opus 5.5（Claude Code auto）合作，将 Mac 头像改成标准 SwiftUI Button，名称和悬停提示为“查看{name}的资料”，点击仍使用现有资料路由；右键提供 `@{name}`，使用现有结构化提及逻辑。头像尺寸 34、头像请求和排版保留。另给 Mac 回复条的叉号补“取消回复”名称与提示。iOS 原点击、长按与震动实现保留。

## 最终正常构建验证

- 确认旧进程退出后打开新构建。真实群消息的辅助功能树显示“按钮 Description: 查看派对没有草东的资料”。
- 通过该具名按钮打开资料卡，鼠标关闭回到原聊天。
- 右键头像显示对应 @ 菜单，选择后输入框出现 `@派对没有草东 `；随后全选删除，没有发送。
- 在已授权的既有文字验收消息气泡上选择回复，辅助功能树出现“取消回复”按钮；鼠标取消，回复条消失。
- 恢复 Something 最新消息及空输入框，没有修改消息或联系人资料。

截图：`/tmp/betterchat-ui-review/chat-avatar-before.png`、`chat-avatar-context-menu.png`、`chat-avatar-mention-draft.png`、`chat-reply-cancel-label.png`。

Mac 构建 `/tmp/betterchat-avatar-controls-mac.log` 与 iOS 构建 `/tmp/betterchat-avatar-controls-ios.log` 成功。本轮是低影响原生控件调整，以真实入口、辅助功能树和截图验证，没有新增镜像实现的单元测试。没有开启系统键盘导航或 VoiceOver，不能据此宣称完整键盘和屏幕阅读器验收通过。
