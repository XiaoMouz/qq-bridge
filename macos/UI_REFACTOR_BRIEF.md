# Claude Code UI 重构任务书

执行主体：Claude Code，模型必须为 `claude-opus-5-5`，使用当前 CLI 的 `--permission-mode auto`。实际运行前核对模型和模式，不自动降级为其他模型，不用跳过权限来代替 auto。用户已明确授权 Claude Code 参与本仓库 UI 重构。

先读根 AGENTS.md、docs/lessons.md、macos/ARCHITECTURE.md、DESIGN.md、PARITY.md、ACCEPTANCE.md 及将修改目录的 AGENTS.md。遵守中文注释与文档约定；仓库已有大量未提交工作，不重置、不覆盖、不提交、不发布、不改版本号。

## 用户要求

- 符合 macOS 27 设计和交互，SwiftUI + UIKit / Mac Catalyst。使用系统 Liquid Glass、原生控件和 SF Symbols，不做网页风大卡片、不用假按钮。
- 页面职责参考 Telegram，视觉密度与控件布局参考 iMessage。
- 消息 / 联系人 / 设置三个主分区放在侧栏底部悬浮标签栏；搜索直接位于侧栏顶部，搜索结果替换列表。
- 聊天信息从标题右侧进入；设置先在侧栏列选项，右侧显示内容。
- 窄窗口单栏列表/详情，清晰的原生返回与切换动画；放大恢复双栏；保留草稿、选中项和子页面。侧栏按钮可收起/恢复。编写按钮和 ⌘N 打开真实收件人选择。
- 图标尺寸、行高、标题高度、控件对齐一致；支持键盘、无障碍名称、减弱动态效果；检查深浅色。
- 默认下载到 Downloads，可在设置选择目录；不改变现有授权和持久化逻辑。
- 包含 iOS 现有全部功能，以 PARITY.md 和当前 iOS 真实源码为基线。不能移除群文件、媒体、转发、回应、语音、通话、搜索、快速回复或设置来让主界面更简洁。

## 协作分工

Codex 负责服务 / ViewModel 契约、工程装配、代码审查、两端构建和 Computer Use 验收。Claude Code 负责 UI 层重构、设计系统、导航协调器与展示层组织。先确认已落地的服务与 ViewModel 接口，直接使用；若需改变接口，写明需求，不创建重复业务状态。

目前 Authentication 和 Conversations 的服务 / ViewModel 已开始抽离。所有文件仍共享同一工作区；开始写代码前说明负责的目录。不要与 Codex 同时改相同文件。

## 功能保留与验证

- 使用已有 AppModel / Session / QQBridgeKit，保持订阅、消息定位、草稿、附件队列、通知跳转和通话入口。
- 不直接操作真实后端、发送消息、推送、呼叫、登录、改通知设置、重启服务或 NapCat。UI 自动化由 Codex 使用 Computer Use 执行。
- 不读取或打印 deploy/.env、凭据、钥匙串、APNs .p8、真实聊天数据库；只读完成重构所需的源码、设计文档和公开 Apple / Telegram 资料。
- 加删 Swift 文件后运行 Mac xcodegen。改共享源码时同时验证 iOS 构建。不要并行运行多次同一派生目录的构建。
- 完成后给出文件清单、依赖边界、功能保留映射、验证命令与剩余问题。不能只返回设计方案或假数据原型。
