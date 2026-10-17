# BetterChat Windows

Windows 原生客户端，使用 C#、WinUI 3 与 Windows App SDK。协议直接来自 `packages/protocol/proto`，不维护另一套消息类型。

当前工作重点是接口、MVVM 和存储分层，设计与实际落地边界见 [架构方案](docs/architecture.md)。[接口覆盖清单](docs/api-coverage.md) 记录 Apple 与 Windows 的调用证据；全部 80 个 RPC 已有可注入契约和传输实现，Apple 基线除用户明确排除的 APNs RegisterPush 外均有调用证据，但完整业务流程与平台适配仍未全部验收。Windows 通知采用 Subscribe + 原生本地通知，适配器已接入，实际通知显示与点击仍待实机验收。下方界面说明记录现有实现，不代表已完成 MVVM 迁移或实机验收。

## 开发

需要 Windows、.NET 10 SDK。NuGet 自动还原 Windows App SDK、protobuf 工具和 SQLite。

```powershell
./windows/generate-api.ps1
./windows/generate-api.ps1 -Check  # 只检查生成文件是否过期，不覆盖文件
dotnet build windows/BetterChat -p:Platform=x64
dotnet run --project windows/BetterChat.Tests
```

生成器更新 ConnectRPC 方法包装；protobuf 类型在构建时通过 `Grpc.Tools` 生成。不要直接编辑生成的文件。

可运行 `./windows/validate.ps1` 一次完成生成一致性、Apple 接口基线、核心回归和独立目录 WinUI 构建；若 Python 不在 PATH，传 `-Python <解释器路径>`。该脚本不启动客户端或执行真实账号操作。

开发运行程序位于 `windows/BetterChat/bin/x64/Debug/net10.0-windows10.0.19041.0/win-x64/BetterChat.exe`。若程序正在运行而导致 DLL 被占用，可以在独立输出目录验证构建：

```powershell
dotnet build windows/BetterChat -p:Platform=x64 -p:OutputPath=bin/validation/
```

## 登录和界面

登录表单输入服务器、QQ Bridge 用户名（默认 `owner`）和密码。客户端调用 `AuthService.Login` 获取设备凭据；密码不保存，返回的凭据通过 Windows 当前用户 DPAPI 加密保存在 `%LOCALAPPDATA%/BetterChat/session.json`。这不是 QQ 密码登录。

连接账号页提供「查看服务端 QQ 登录状态」调试入口。未登录时在本地生成二维码，由用户自行扫描；刷新二维码必须显式点击。状态查询仅在页面可见且 QQ 未登录期间进行，离开页面或退出账号会取消请求。该入口不替代 Bridge 密码登录。

未登录时只显示引导页和登录表单。登录成功后，最左侧贯穿应用内容区的整条导航栏显示消息、联系人、设置与当前 QQ 账号头像；中栏是当前分类的列表；右栏显示会话或详情。顶部搜索栏支持消息搜索和本地联系人、群聊匹配。`Ctrl+K` 聚焦搜索，`Enter` 发送，`Shift+Enter` 换行。

## 当前实现与待验收

这是开发中的客户端，尚未达到现有 iOS / Mac 客户端的完整功能覆盖。

| 模块 | 当前实现 | 仍需完成或验证 |
|---|---|---|
| 外壳 | NavigationView 紧凑导航（未读 InfoBadge、设置与账号在底部）、TitleBar 返回 / 展开导航、右栏页面栈（Alt+← 与鼠标返回键）、会话行（时间、置顶 / 免打扰、@ / 回复 / 全体、未读胶囊、右键菜单）、SelectorBar 筛选、三档自适应（<640 一栏）与列表宽度拖动、`Themes/Tokens.xaml` 设计数值、系统主题、Mica、共享应用图标 | 窄窗口下聊天页验收、完整键盘及高对比度验收；右键菜单的写操作未实测 |
| 账号 | 密码登录、DPAPI 凭据及旧格式修复、设备 MVVM、离线退出协调 | 登录／退出／撤销设备真实交互验收 |
| 同步 | SQLite v2、pts / chat_pts、Subscribe、缺口补齐、首屏预取、退避重连；真实冷启动读取通过 | 多设备实时联调、长时间断线恢复 |
| 消息 | 持久化幂等发送／回复、撤回／回应 MVVM、多条消息／多目标和合并转发、双向历史、草稿、已读协调 | 真实发送／回复／撤回、多选转发与滚动／提及交互验收 |
| 搜索 | 全文分页、循环游标防护、取消、联系人匹配、会话内搜索；真实全局／会话分页及原消息定位读取通过 | 结果高亮、真实界面跳转与完整返回路径 |
| 媒体 | 附件上传续传校验、预览磁盘缓存及清理、按需图片／音视频、转文字、AI 语音 MVVM、表情和嵌套转发阅读器、录音状态机与 Windows 采集适配 | 麦克风权限／采集／语音发送实机验收；上传到 QQ、播放、表情／转发阅读器实机验收 |
| 联系人 | 好友／群目录缓存、资料、群成员／公告／精华、群文件管理 MVVM、相册媒体分页 | 修改／删除动作真实验收，群内容实际交互与分页 |
| 设置 | 主题、设备、存储概览／分类／媒体分页 MVVM、清理预估／确认、分层存储策略 MVVM、服务端状态与存档管理 MVVM；策略和清理请求纳入账号生命周期 | 真实管理链路验收，其他业务入口的生命周期迁移继续核对 |
| 通话及通知 | 通话状态与协调接口、Subscribe → Windows 本地通知适配器及过滤策略 | 通知显示／点击实机验收；真实通话音频适配后置 |

核心测试使用内存 HTTP 响应与临时 SQLite，不连接真实账号、不发送 QQ 消息。编译成功和离线测试不能代替上述真实链路验收。

### 当前验证证据与剩余关卡（2026-10-16）

- 核心回归 150 项通过；WinUI 独立目录构建零警告零错误。数据库查询计划已验证主键／范围查找及活动发件箱索引，列表／搜索／资料入口改用后台联系人快照，联系人未变化时不重复查询解码，尚无真实窗口切换性能结论。
- 最近真实只读验收 36 项通过、0 失败，新增群成员 ViewModel 首屏／下一页追加与去重；存储分类会话、媒体分页及引用位置、全局与会话搜索分页和搜索原消息定位均通过。相册为空、历史页没有预览哈希，对应分支明确跳过。此前预览下载／哈希／离线缓存已实际通过。
- 静态审计：80 个 RPC，Apple 调用基线 65 个，唯一平台豁免为 APNs RegisterPush，其余未发现缺少调用证据。语音录音这类平台功能不由 RPC 调用计数证明。
- 2026-10-17 已获窗口验收授权，并用独立调试构建验证群聊／私聊切换、历史向上滚动、全局搜索与结果定位、标题栏正常关闭；关闭后窗口与进程均消失。未发送消息或撤销设备。测试群文字／回复／撤回仍待授权，设备撤销和清理等真实破坏性操作也未执行。
- `git fetch` 的 SSH agent 签名失败；限定本次命令的直接 HTTPS 尝试停在凭据助手选择器，结束该选择器后返回无法获取密码。最新非交互 SSH 重试仍返回 `Permission denied (publickey)`。没有替用户登录或改全局 Git 配置。当前协议对齐以本地 checkout 为准，不能宣称已对齐尚未拉取的远端提交。
- 本地缓存迁移为 schema v2，临时旧库迁移及失败回滚通过；未升级用户实际缓存。支持 v1 的旧客户端会拒绝打开 v2 缓存，不应手动改低版本号。

复验命令：

```powershell
dotnet run --project windows/BetterChat.Tests
dotnet build windows/BetterChat -p:Platform=x64 -p:OutputPath=bin/architecture-validation/ --nologo
python windows/audit-api.py --require-parity
dotnet run --project windows/BetterChat.Check -- --read-only
```

只读工具使用已有受保护会话，不替用户登录，不输出令牌或消息正文，不修改用户消息库。麦克风录音的应用层状态机及 Windows 适配已落地，入口在聊天菜单“录制语音”，真实权限、采集和发送仍需验收；通话媒体接入按用户要求后置。

## 2026-10-16 界面与性能修复

- 使用 WinUI TitleBar 合并应用图标、搜索和窗口按钮，去掉重复的系统标题栏；直接引用 iOS AppIcon 资源。
- 会话和联系人按稳定键增量更新，单行预览去除换行；联系人索引按修订缓存，消息行不再反复读取整份会话表。
- 切换页面先保存本地草稿，后台串行提交已修改的草稿；历史首屏不等待全局同步队列。
- 消息采用数据项和可回收容器，进入视口才创建内容；缩略图预留尺寸并限制解码尺寸。
- SQLite 增加会话/序号索引，按历史窗口读取消息与事件，保留实时更新和搜索历史隔离。
- 20 项离线测试通过。合成万条缓存连续读取 50 次，整群读取 1232 ms，窗口读取 126 ms；这是读取基准，不代表界面帧率。

开发验证程序：`windows/BetterChat/bin/composer-validation/BetterChat.exe`。没有修改版本号或生成发布包。

### 列表头像

会话与联系人复用 proto 的 `Peer.avatar_sha256`；缺失时通过 `GetAvatars` 分别查询用户和群，再签名媒体 URL。仅可见行发起加载，最多 4 个并发请求，96 像素解码，最多缓存 512 个头像任务。行复用与页面退出会取消排队并检查对象身份，失败保留姓名占位。已在登录态验证真实好友与群头像。

### 聊天状态与已读

消息首屏显示加载提示、空状态和失败重试；网络失败时已缓存消息仍可阅读。已读以当前加载的消息序号为准，仅在窗口激活、查看最新历史且位于底部时延迟合并提交；历史定位不自动标记最新已读。请求失败可重试，不推进本地确认位置。已读合并/失败重试回归加入后共 21 项测试通过。

### 群成员提及

群聊输入框的 @ 按钮打开原生选人对话框，支持成员分页，以及按已加载成员的群名片、昵称、QQ 号筛选。管理员/群主有全体成员入口。提及发送与草稿均保留 proto 实体 ID；显示名相同不会按名字映射用户。修改提及内部文字后，该段退回普通文本；手写 @ 不自动生成实体。结构化草稿恢复还保留原有表情段。21 项核心测试通过，包括重名成员选区删除和混排编辑。

### QQ 小黄脸与混排

Windows 复用 iOS 的 `Resources/QQFaces` 图片和 `QQFaceNames.swift` 名称目录，执行 `windows/generate-faces.ps1` 可更新本地 JSON 元数据。当前包含 372 个有图片的条目，265 个非隐藏表情可在选择面板中按名称/编号搜索。选择后保留 `OutgoingSegment.face_id`，发送与草稿共用实体模型；聊天中的文字、提及、小黄脸使用 WinUI 段落内混排。超级表情目前显示静态图片，未接入动画。

本轮开发构建为 `windows/BetterChat/bin/faces-validation/BetterChat.exe`，编译与资源解码检查通过。遵循用户停止电脑操作的要求，没有切换正在运行的客户端；表情面板与混排视觉效果仍需实机验收。

### 合并转发阅读器

单个 WinUI 对话框内支持嵌套记录展开/返回、发送者与时间、文字/提及/小黄脸、已有媒体缩略图和图片/音视频预览。节点使用可回收列表容器，预览限制并发；关闭时取消请求并停止播放。按 `GetForward.path` 导航，最多 8 层；`mediaReady.forward_path` 匹配当前层后合并刷新，无定时轮询。不使用普通消息的 `RequestMedia` 去请求转发节点，未准备好的媒体保留状态与重载入口。

构建输出：`windows/BetterChat/bin/forward-validation/BetterChat.exe`。本轮没有操作运行中的客户端，嵌套导航、播放和弹窗关闭仍需实机验收。

### Windows 本地通知（2026-10-16）

通过 Windows App SDK 的 AppNotificationManager 注册本机通知激活处理器，并由运行期间的 Subscribe 消息触发提醒。这里的 Register 是操作系统本地注册，不调用后端 RegisterPush，不使用 APNs，也未接入 WNS。

应用层 MessageNotificationPolicy 负责自身消息、当前前台会话、已读消息、免打扰、归档、提及和重复事件过滤。历史查询及补差不触发通知；每条消息在后台按主键读取当前会话策略，避免扫描全量联系人。通知点击仅处理当前运行会话，退出或切换账号会移除该组通知，旧会话点击不会打开新账号内容。

限制：关闭程序后不接收推送，不支持通知冷启动后自动定位。proto Message 没有实时/历史来源标志，因此订阅中出现的近期历史入库只能靠时间边界过滤。原生注册依赖机器具备对应 Windows App SDK 运行组件；失败原因显示在“连接与账号”。实现参考 [Microsoft 原生通知文档](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-dotnet)。

通知策略回归加入后共 73 项测试通过；WinUI 构建通过。未启动或操作用户正在运行的客户端，系统弹出、权限设置与点击定位仍需实机验收。

### 发送 ID 与重试内容校验（2026-10-16）

对照后端 outbox/service.ts 与 Apple Sender.swift，修复 Windows 原先生成 63 位 client_random_id 的错误：后端 Number.isSafeInteger 只接受安全整数，现由应用层 MessageIdentity 生成 1…2^53−1 范围内的随机 ID，文本与附件共用。运行时在入库和网络请求前拒绝越界 ID。

本地幂等校验同时检查已确认 outbox 与未确认 pending；同一 ID 不允许改变会话、回复或消息内容，失败消息沿用原请求重试。启动时在本地事务中恢复旧版本正数越界待发送 ID：仅当该 ID 没有服务端发件箱记录时生成合法新 ID，保留原文字、附件引用和回复关系，不自动发送。合法未确认 ID 原样保留，避免网络超时后重复发送；若已有服务端记录则不擅自改 ID。

新增安全整数边界、非法请求零网络副作用、已确认条目内容不可变、旧数据恢复与重复重开、恢复失败完整回滚回归，77 项测试通过。本轮未向真实 QQ 会话发送消息。

### 发送确认与同步收尾（2026-10-16）

Subscribe／补差收到 outbox 确认后，在同一 SQLite 事务中清除内容匹配的本地 pending，避免发送 RPC 回包丢失后残留隐藏待发送项，并在缓存重建时重新出现。只有带正 pts、已知状态且会话、回复和段落完全匹配的确认才收尾本地请求；冲突内容保留。既有版本比较保证迟到 RPC 不能覆盖较新 sent，RPC 确认也不单独推进全局 pts。

新增同步先到、旧回包后到、缓存重建、冲突确认以及触发器模拟写入失败的事务回滚测试，共 80 项测试通过。尚未执行真实 QQ 发送验收。

### 只读接口验收

在 Windows 客户端已有登录会话后运行：

```powershell
dotnet run --project windows/BetterChat.Check -- --read-only
```

工具复用本机受保护凭据，不替用户登录；检查状态、同步、联系人、历史与存储，并在有可用预览时验证真实下载与离线缓存。仅输出接口名、状态及耗时，不打印凭据或聊天内容。2026-10-16 实测 16 项通过、0 项失败；发送、写入和 WinUI 交互不在此检查范围。
