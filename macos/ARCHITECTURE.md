# BetterChat Mac 架构与重构边界

2026-10-14：本次目标是由 Codex 与 Claude Code 协作重构 macOS UI，并拆清页面状态与业务依赖。本文区分已落地和待完成内容，不把目录迁移或编译通过等同于完整重构。

## 技术与工程约束

继续采用用户已确认的 Swift 6 + SwiftUI + UIKit / Mac Catalyst，macOS 27、Mac idiom。Apple 的设计文档不强制 MVVM 或某一目录名称；本项目采用按功能组织的 MVVM + Coordinator，并用 XcodeGen 维护工程，避免同时手改生成工程与项目描述。

QQBridgeKit 保持独立 Swift 包，负责协议、持久化、同步、发件箱、媒体缓存。桌面 UI 不重新实现后端协议、不引入另一套同步机制。现有共享 iOS 页面暂作为完整功能基线；后续共享展示组件与平台适配器要有明确接口，不能以复制全套 iOS 源码或删除功能代替解耦。

## 依赖方向

```text
Application（生命周期、依赖装配）
  ├── Coordinator（窗口、路由、弹窗、快捷键）
  └── Features
        ├── Views（SwiftUI / UIKit 展示、布局、焦点）
        └── ViewModels（可观察页面状态、用户意图、取消和错误）
              └── Core/Services（可注入协议及 Session 适配器）
                    └── QQBridgeKit（协议、数据库、同步、缓存、发件箱）
```

- View 不发送 RPC、不读 UserDefaults、不创建同步任务。UIKit 控制器允许拥有 diffable data source、控件焦点和布局缓存，这些是展示状态。
- ViewModel 不持有 UIViewController、UINavigationController、AnyView，不直接弹窗、不调用 UIApplication.shared；输出状态和导航意图。
- Coordinator 决定显示哪一页，保存各分区导航与按会话 ID 隔离的进程内草稿（切换会话只重建页面，不缓存历史控制器）；不能承担数据库查询、输入校验、列表过滤与消息策略请求。
- 服务封装 Session / API / store，接口可注入假实现；错误继续到 ViewModel，不能吞掉后只给 UI 一个成功状态。
- 页面级任务随 ViewModel 生命周期取消；过期请求不得覆盖新页面。登录密码不写 UserDefaults，不记录到日志。
- 状态单一所有者：窗口路由属于 Coordinator，页面加载状态属于对应 ViewModel，连接/通话等应用状态属于现有 AppModel，业务数据属于 QQBridgeKit。

## 当前目录

```text
macos/BetterChat/
  project.yml
  App/
    Application/                 # App / Scene / 依赖装配
    Navigation/                  # 窗口与页面协调器、路由类型
    Core/Services/               # 服务协议、Session / 系统适配器
    DesignSystem/                # 统一间距、图标、材质及可复用原生控件
    Features/
      Authentication/{Views,ViewModels}/
      Workspace/{Views,ViewModels}/
      Conversations/{Views,ViewModels}/
      Search/{Views,ViewModels}/
      Contacts/{Views,ViewModels}/
      Settings/Views/             # 设置列表状态由 Workspace ViewModel 管理
      Downloads/{Views,ViewModels}/
      QuickReply/Views/
      Shared/                    # 纯展示数据、名称与搜索键
      Camera/
      GroupContent/{Views,ViewModels}/
  Resources/
macos/tests/                     # 无真实账号写操作的状态/服务检查
```

不为满足目录图创建空壳层。每个迁移单元必须连到实际界面并通过构建；`project.yml` 是唯一工程来源。共享 iOS 展示层迁移需同步更新两个工程，保留通知扩展及资源引用。

## 本轮已落地的架构基础

- 登录：`MacAuthenticationService`、`MacLoginPreferences` 与 `MacLoginViewModel`。登录控制器只处理控件、焦点和状态渲染；App 入口注入原有登录流程。
- 登录状态检查覆盖空输入、防止重复请求、失败后重试、成功后清除密码、取消和旧请求返回隔离。
- 会话：`MacConversationService` 封装订阅、手动同步、置顶、已读和通知策略请求；`MacDialogsViewModel` 持有会话集合、选择、归档分区、未读定位及操作错误。列表控制器保留差量渲染与原生菜单，将用户意图交给 ViewModel。
- 原始源码快照：`/tmp/betterchat-mvvm-baseline-20261014`，不包含运行数据、令牌或构建缓存。

## Claude Code 协作结果

用户恢复授权后，Claude Code 从 2.1.235 更新到 2.1.299，并实际以 `claude-opus-5-5`、`permissionMode: auto` 完成三轮实现与修订。交接见 [CLAUDE_HANDOFF.md](CLAUDE_HANDOFF.md)，Codex 的独立复核见 [REFACTOR_REVIEW.md](REFACTOR_REVIEW.md)。

1. 原来的 `MacWorkspaceController`、`MacConversationsController`、`MacSidebarSearch` 和 `MacSidebarControls` 已拆除。依赖在 `MacWorkspaceAssembly` 装配，分区/页面由 `MacWorkspaceCoordinator` 协调；页面工厂、聊天协调器、宽窄窗口容器、工具栏和命令路由分别独立。
2. 搜索与联系人增加协议服务和 ViewModel；搜索结果是纯值，不携带 `AnyView`。分区保留独立搜索草稿，离开分区或由外部打开会话时取消旧的联系人打开请求；下载设置使用 `MacDownloadPreferences` 可注入协议。
3. 尺寸、符号和原生控件集中在 DesignSystem。共享 `DialogRow` / `ArchiveRow` 接受纯尺寸参数，iOS 默认值保持 48 / 56 / 12，Mac 传入 40 / 48 / 10；没有给共享类型新增 Mac 专属依赖。
4. 实测宽/窄列表与详情导航、联系人群文件子页面保留、编写、侧栏开关、草稿保留、侧栏搜索与消息定位；已检查深浅色，并基于截图修订选中态对比度。具体证据与限制在复核记录。

## 共享边界与验证范围

Mac 独立页面的状态和服务已按上述方式分层。现有共享 iOS 聊天、资料、存储等业务页面仍使用原有实现，部分异步状态仍在 SwiftUI 页面内；本轮没有把整个 iOS App 全部迁移成 MVVM，也没有建立另一套聊天业务逻辑。共享页面通过页面工厂接入 Mac，完整功能入口继续保留。

`python3 macos/tests/run_state_checks.py` 运行七组检查，不访问真实账号；Mac 与 iOS 构建、Mac 签名校验通过。截图验收不替代硬件、真实通话、离线重连和全部写操作验收；这些状态继续以 [PARITY.md](PARITY.md) 为准。

## 参考

- [Apple Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
- [Apple Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Telegram macOS 官方源码](https://github.com/overtake/TelegramSwift)

应用级状态检查位于 `macos/BetterChat/Tests`，由 XcodeGen 的 `BetterChatMacTests` target 直接加载生产 ViewModel；DEBUG 测试宿主通过仅 Test action 的环境变量隔离账号恢复与推送，普通 Run 不受影响。用例与执行方式见 [测试说明](tests/README.md)。

群相册照片页仅 Mac 接入 `MacAlbumMediaService` → `MacAlbumMediaViewModel` → `MacAlbumMediaView`，服务负责原协议请求，模型负责分页游标、去重、错误重试及取消后的迟到响应隔离。共享 `AlbumMediaView` 只做平台分派；iOS 原页面和编辑能力保留。

公告及相册列表使用 `MacGroupListService<Item>` 的两个 Session 适配器，统一由 `MacGroupListViewModel` 管理首屏、刷新、取消与错误；`MacGroupListPage` 展示首屏重试或保留内容的错误条。共享页面只提供原有行内容、封面与 NavigationLink，iOS 的原加载分支保留。群精华使用 `MacGroupEssenceService`、`MacGroupEssenceViewModel` 与 `MacGroupEssencePage`，独立管理请求和媒体就绪订阅；离开取消请求及监听，迟到响应失效，刷新失败保留内容并可重试。返回仍含待就绪媒体的页面时先重新加载快照，补偿离开期间无法重放的临时事件。媒体按钮复用 Mac 独立窗口展示，iOS 原展示分支保留。

原生导航投射会缓存按钮 enabled 快照，不能只比较 UIBarButtonItem 身份；SwiftUI 布局提交之后合并再取一次最终导航状态，避免异步刷新完成后 Catalyst 可见按钮仍禁用。具体实机诊断及验证见 GROUP_CONTENT_UI_REVIEW.md。


Mac 媒体独立窗口通过 `MacMediaWindows` 交付一次性场景请求，由 `MacMediaSceneDelegate` 装配单个媒体窗口。`MacMediaWindowContext` 只管理关闭与资源生命周期，不创建第二套 Session、同步或主工作区；共享媒体页面在 Mac 经此路由，iOS 继续原展示方式。Mac 每个 VideoPreviewModel 拥有自己的 VideoPlayback，窗口之间不会替换彼此的控制器。

## 2026-10-15 侧栏职责整理

移除编写收件人选择、会话操作下拉菜单及 ⌘N / ⌘R；手动同步在 `MacSyncSettingsView`，通过现有 router 与 `MacManualSync` 执行、保留跨页忙碌/错误状态。群助手返回属于 `MacSidebarView` 的列表导航区；`MacDialogsController` 管页面过渡和按会话锚点恢复滚动，实时消息快照继续禁用重排动画。

会话内查找单独拆成 `MacChatHistoryService` → `MacChatHistoryViewModel` → `MacChatHistoryView`。会话 ID 固定，关键词变更/离开取消旧查询，代次防止迟到结果覆盖；iOS `ChatSearchView` 仅在 Catalyst 分支进入此页。Mac 私聊详情显式传当前会话 ID，避免由 peer 反查错误的临时/普通私聊。搜索框位于内容顶部，使用系统 UISearchTextField，不依赖隐藏的内层导航栏。


群文件列表在 Mac 使用 `MacGroupFilesService` / `MacSessionGroupFilesService` 封装群与目录查询，`MacGroupFilesViewModel` 持有文件夹、文件、选择、加载和错误状态。成功响应原子更新列表及操作 ID 对应的选择，失败保留旧内容；刷新合并为一个任务，离开页面取消并使迟到响应失效。共享 `GroupFilesView` 的下载、预览、分享、转发与管理操作继续使用原协议，Mac 通过条件分支绑定模型和 `MacGroupListStatus`，iOS 保留原加载实现。


会话共享媒体在 Mac 由 `MacSharedMediaService` 和 `Features/Media` 下的 `MacSharedMediaViewModel` 管理查询与分页。类型或排序切换先取消旧任务并换代，再重置两类游标；普通失败保留当前列表/游标、显式重试，最新排序按 seq 递减，其余按 offset 递增，异常游标停止自动翻页。同一消息的媒体用 seq/kind/ord 区分，重复回包更新原项而不吞掉其他附件。共享视图仅绑定模型、显示状态和路由媒体窗口，iOS 保留原分页分支。
