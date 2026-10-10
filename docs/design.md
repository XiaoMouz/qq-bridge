# QQ Bridge 设计方案：基于 NapCat 的类 Telegram 消息存档服务端 + 自研原生 iOS 客户端（含 QQNT 通话桥接）

## 0. 背景与目标

- **痛点**：
  - QQ 的消息和媒体都依赖腾讯云端：漫游时间受限；图片、视频、文件链接带 rkey，会过期；群文件和离线文件到期即失效；消息被撤回后就看不到了。
  - 官方客户端的多端同步和检索体验一般，而且手机上的本地缓存越来越大。
- **目标**（个人自用，不公开、不商用）：
  1. 服务端**持续、完整地存档**消息和媒体。媒体统一存在服务端，**按哈希去重**，单个资源只保存一份；能**按会话统计和优化占用空间**；能看出**某个媒体在哪些会话里出现过，并且可以跳回原消息的上下文**。
  2. 后端按 **Telegram 的思路**设计：服务端是唯一真相源，多设备增量同步（pts / getDifference），离线后能快速追平，支持统一检索。
  3. 自研**原生 iOS 客户端**（Swift，iOS 27 Liquid Glass）。**本地只做有上限的缓存**，不长期保存大量媒体。
  4. **在 App 内桥接 QQNT 的语音通话、视频通话和群语音通话**，并保存通话记录。这项只针对 NapCat 环境实现。
- **已确认的约束**：服务端用 TypeScript；客户端是原生 iOS 自研；上游以 NapCat 为主；**目前只有这台 MacBook 可用**（还没有常开的主机）；工作区目前为空，是全新项目。

## 1. 调研结论速览

**消息与上游框架**

| 项目 | 结论 |
|---|---|
| NapCatQQ | TypeScript，pnpm monorepo，包括 `napcat-core`、`napcat-onebot`、`napcat-shell`、`napcat-framework` 等包；只提供 OneBot 11 及大量私有扩展。★10.8k，v4.18.28 发布于 2026-09。**有插件系统**：`plugin_init(ctx)` 能拿到 `ctx.core`（内核会话和服务）、`ctx.actions`、`ctx.router`。许可证：禁止商用，修改版不得公开（自用不受影响）。 |
| 运行模式 | **Shell**：无头运行。Linux 上的做法是把 QQ 的 `resources/app/package.json` 入口改成 `loadNapCat.js`，再用 `xvfb-run` 启动；官方 Docker 镜像 `mlikiowa/napcat-docker` 用的就是它。**Framework**：注入到完整 QQ 图形界面里，官方有头镜像是 `NapCat.Docker.Framework`。维护者对有头模式更推荐 SnowLuma（#2067）。 |
| 消息标识的坑 | OB11 里的 `message_id` 是内部 int32 短 ID，**真实序号在 `real_seq`**；要按 seq 精确补历史，需要在插件里调用内部 API。 |
| Milky 1.3 | 消息主键 = scene + peer + seq；没有"最近会话"接口，也没有通话接口；只作为消息层面的退路。 |
| 先例 | QQ Chat Exporter（NapCat 插件做采集，★5.4k）。 |
| Teamgram | 开源版功能不全，所以不兼容 MTProto，只借鉴 Telegram 的同步语义。 |

**通话**

| 项目 | 结论 |
|---|---|
| Linux QQ 通话 | 3.2.9 起支持音视频通话，3.2.10 起 amd64 和 arm64 都支持，并能和手机互相转接。 |
| 技术栈（腾讯官方文章） | 引擎是 NTRTC（原 AVSDK），打包成 PPAPI 插件 **`resources/app/avsdk/libAVSDKPlugin.so`**，MIME 类型是 `application/x-ppapi-avSDK`。插件运行在独立进程里，内含 NTRTC、**GroupVideo（群通话）** 和 BroadCast-Core；没有 GPU 时退回 Graphics2D 软件渲染。 |
| 官方态度 | NapCat 维护者对通话接口的答复是"没有计划"（#1678）。 |
| **已验证的先例（关键）** | **maibot-qq-voice-call 的 QQ AV Bridge**（GPL-3.0，2026-08，要求 NapCat ≥ 4.14 + Linux QQ）已经实现了**不需要 QQ 图形界面**的来电接听和双向语音：<br>1. **NapCat 插件**：用 `session.getAVSDKService().addKernelAVSDKListener()` 监听内核的通话事件（`onInviteActionToAVSDK`、`onActionToAVSDK`、`onS2CActionToAVSDK`、`onGroupVideoActionToAVSDK` 等），把内核数据转发给 AV Host；再把 AV Host 输出的网络数据通过 `setActionFromAVSDK()` 交回内核。<br>2. **AV Host**：用 QQ 自带的 Electron 起第二个进程（改了 `loadNapCat.js`，用环境变量分流，可以还原），通过 `--register-pepper-plugins` 在隐藏窗口里加载 `libAVSDKPlugin.so`，用 `embed.postMessage({cmd, id, param})` 调用。<br>3. **隔离的 PulseAudio**：把 `*_speaker` 设为 QQ 的默认扬声器（读它的 monitor 就是对方声音），`*_mic` 灌入的声音经过 remap 后作为 QQ 的默认麦克风。<br>**它没有做**：主动拨打、拒接和挂断控制、静音、视频、群通话。 |
| 推论 | **通话不需要完整 QQ 图形界面，也不需要模拟点击**：用 NapCat **Shell** 加一个 AV Host 即可，信令在插件和 AV Host 之间转发，语音通过 PulseAudio 进出。还没覆盖的能力（拨打、挂断、静音、群通话、视频），可以在有头 QQ 里"录制"官方界面发给插件的指令序列，再在 AV Host 里重放。 |
| WebRTC 组件 | LiveKit（Apache-2.0，自带 TURN），`@livekit/rtc-node` 1.1.0（推送和接收原始帧），LiveKit Swift SDK。 |
| CallKit | 中国区 App Store 上的应用不能使用 CallKit；收到 VoIP push 必须上报给 CallKit。个人签名的 App 需要真机验证，必要时降级。 |

**本机环境**：macOS 15.7.4，Apple M2，16GB 内存；没有安装 Xcode，磁盘可用约 30GB；已有 OrbStack、Tailscale、Node 26、pnpm 9。Xcode 27 需要 macOS 26.6 及以上。

## 2. 上游选型：NapCat 为主，插件式二开

| 维度 | NapCat 路线 | Milky 路线（LLBot / Yogurt） |
|---|---|---|
| 语言与技术栈 | TypeScript/Node，运行在 QQNT 自带的 Electron Node 环境里 | LLBot 是 TS（有头或无头）；Yogurt 是 Kotlin（纯协议） |
| 二开方式 | 插件在进程内运行，可以直接调用 core，不需要 fork | 一般直接消费标准接口；需要规范外能力时 fork（GPL） |
| 存档能力 | 能拿到原始 seq、按 seq 区间拉取、最近会话、本人从其他设备发出的消息 | 规范保证 seq 唯一；没有最近会话接口 |
| 通话桥接 | **可行，已有先例**：插件能拿到内核的 AVSDK 监听器和 `setActionFromAVSDK` | 不可行，没有接口 |

**结论**：
- **生产环境用 NapCat Shell**（在官方 `napcat-docker` 镜像基础上派生），加上**第二个 Electron 进程 AV Host** 来承载通话引擎。不修改 NapCat 源码，所有扩展都放在自研插件和 AV Host 里。
- 有头镜像（NapCat.Docker.Framework + noVNC）**只作为研究工具**，用来录制官方界面的通话指令，不进入生产。
- Milky 只作为消息层面的退路，接上它就没有通话功能。

## 3. 总体架构

```
┌──── QQ 宿主（阶段 A：MacBook 上的 OrbStack）：qq 容器 + call-gateway sidecar ────┐
│ Xvfb · 隔离的 PulseAudio（qq_speaker 扬声器 / qq_mic 麦克风）· supervisord       │
│ 进程 1：QQ(Electron) + NapCat Shell + napcat-plugin-qqbridge                    │
│   · 消息：OB11 事件 + 原始字段 → 本地 JSONL 队列（ack 游标）；RPC 透传 + 扩展      │
│   · 通话信令：内核 AVSDK 监听器 ⇄ HTTP（仅回环地址）⇄ AV Host；                   │
│     接听、拨打、挂断等动作在这里编排                                              │
│ 进程 2：AV Host = QQ(Electron) + libAVSDKPlugin.so（PPAPI，隐藏窗口）            │
│   · 媒体直接连腾讯服务器；声音进出 PulseAudio；需要视频时窗口才在 Xvfb 上显示     │
│ call-gateway（sidecar，共享网络命名空间和 Pulse socket，@livekit/rtc-node）：    │
│   qq_speaker.monitor ─parec─▶ LiveKit；LiveKit ─pacat─▶ qq_mic；                │
│   需要视频时：x11grab 截 AV Host 窗口 ─▶ LiveKit；LiveKit ─▶ v4l2loopback（阶段 B） │
└──────────▲──────────────────── WebSocket（token）───────────────▲───────────────┘
           │                                                     │ WebRTC
┌──────────┴────────── qqbridge-server（Node 24+，TS）──────────┐  ┌──┴──────────┐
│ 上游适配 · 摄取（单写者）· 媒体（去重/引用/配额/冷热）· 同步（pts） │  │ LiveKit SFU │
│ ConnectRPC API · 媒体 HTTP · APNs（含 VoIP）· PGroonga · 通话状态机│  │（自带 TURN） │
└──────────▲─────────────────────────────────────────────────────┘  └──▲──────────┘
           │ HTTPS/HTTP2（Tailscale）                                 │ WebRTC
┌──────────┴──────────── iOS App（Swift 6，iOS 27，Liquid Glass）──────┴──────────┐
│ SyncEngine · GRDB（缓存有上限）· Nuke/AVFoundation · LiveKit Swift · CallKit/通知 │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## 4. 服务端设计（TypeScript）

### 4.1 技术栈
- 运行时：Node.js 24 LTS 及以上，TypeScript strict 模式，pnpm workspace。
- API：Fastify + ConnectRPC（`@connectrpc/connect-fastify`、`@bufbuild/protobuf` v2）；用 buf 管理 proto，**同一份 proto 同时生成 TS 和 Swift 代码**。
- 存储与队列：PostgreSQL 17 + PGroonga；Drizzle 负责迁移，复杂查询写原生 SQL；任务队列用 pg-boss。
- 媒体处理：sharp、ffmpeg、silk-wasm、thumbhash。
- 实时音视频：LiveKit server + `livekit-server-sdk`（签发令牌）+ `@livekit/rtc-node`（网关里使用）。
- 推送：`@parse/node-apn`（普通 alert 推送和 VoIP 推送）。
- 其他：zod、pino；测试用 vitest + Testcontainers + fast-check。

### 4.2 仓库结构（全部为新建）
```
qq-bridge/
├─ proto/qqbridge/v1/*.proto       # 客户端协议的唯一真相源
├─ packages/
│  ├─ domain/                      # 领域模型（Milky 语义）、消息段规范化
│  ├─ server/                      # API、ingest、sync、media、storage、push、search、calls
│  ├─ upstream-napcat/             # 插件协议客户端 + OB11→领域映射
│  ├─ upstream-milky/              # Milky 适配器（只管消息，P6）
│  ├─ napcat-plugin-qqbridge/      # NapCat 插件：消息采集 + 通话信令模块
│  ├─ av-host/                     # AV Host（host.cjs + host.html，参考 maibot 的实现）
│  └─ call-gateway/                # PulseAudio / X 显示 ⇄ LiveKit 的媒体桥
├─ ios/                            # Xcode 工程：App + NotificationService + Share 扩展
├─ deploy/
│  ├─ qq/Dockerfile                # 基于 mlikiowa/napcat-docker，加上 PulseAudio、supervisord、
│  │                               #   带开关且可还原的 loadNapCat.js 分流、锁定版本的 QQ 和 NapCat
│  ├─ qq-gui-lab/                  # 研究用：有头镜像 + noVNC，用来录制官方通话指令
│  └─ docker-compose.yml           # qq / call-gateway / server / postgres / livekit / tailscale
├─ tools/avsdk-recorder/           # 指令录制脚本（在有头 QQ 中挂钩 embed.postMessage 和内核监听器）
└─ fixtures/                       # 消息样本、AVSDK 指令序列样本（脱敏）
```

### 4.3 上游层
- **`UpstreamPort` 接口**（领域语义）：
  - 消息：事件包括收到消息（含本人从其他设备发出的）、撤回、回应、戳一戳、文件、置顶、好友/群变更、上线/离线；动作包括 `getHistory(scene, peer, fromSeq, limit)`、`listRecentContacts`、`resolveMediaUrl`、`send`、`recall`、`markRead`、`react`、`nudge`、`setTyping`。
  - **通话**（只有 NapCat 实现）：
    - 事件：CallIncoming、CallStateChanged（振铃、接听中、已接通、已结束及原因、在别处接听）、GroupCallStarted/Ended。
    - 动作：`answerCall`、`declineCall`、`hangup`、`startCall(peer, voice|video)`、`joinGroupCall(group)`、`setMute`。
- **NapCat 插件（保持很薄）**：
  - **消息模块**：OB11 事件 + 补齐原始字段 → 本地 JSONL 队列 → WebSocket 推给服务端，服务端按游标 ack；RPC 透传 `ctx.actions`，另有扩展 `x.history_by_seq`、`x.media_url`、`x.recent_contacts`。
  - **通话信令模块**（参考 maibot 的实现，GPL-3.0，自用不分发）：
    1. 注册 `addKernelAVSDKListener`。
    2. 把内核数据转发给 AV Host（指令 55）；把 AV Host 输出的网络数据通过 `setActionFromAVSDK` 交回内核。
    3. QQ 登录后让 AV Host 登录（指令 1）。
    4. 收到来电**先挂起**，等 iPhone 端接听后再发接听指令（指令 5）；maibot 原来是 500ms 后自动接听，这里要改。
    5. 维护通话阶段：振铃、接听中、已接听、已接通、已结束。
    6. 只监听回环地址，使用 32 字节以上的 Bearer token。
  - 约束：不引入原生模块；依赖的内部 API 保持最少，NapCat 或 QQ 升级前跑回归测试。
- OB11 → 领域的映射放在服务端；Milky 适配器只管消息（P6）。

> **实现备注：上游链路**
>
> 代码位置：插件 `napcat-plugin-qqbridge/src/upstream/*`，服务端 `server/src/upstream/*`。
>
> - **连接**：插件主动连 `ws://<服务端>/upstream/napcat`，带 `Authorization: Bearer <UPSTREAM_TOKEN>`。在 OrbStack 里，服务端只监听 127.0.0.1，容器也能通过 `host.internal` 连上。
>
> - **协议 v1**（JSON）：
>   1. 插件发 `hello`，带队列 id、本地最早和最新游标、QQ 号。
>   2. 服务端回 `welcome{resume}`，告诉插件自己已存到哪个游标。
>   3. 插件按批发送 `events`；服务端写进收件箱并提交后，回累计确认 `ack{c}`；插件据此清理本地分段。
>   4. 同一条连接上，服务端可以发 `req`，插件回 `res`。可调用的动作：
>      - `x.media_url`：按定位信息换新下载链接；
>      - `x.history`：按 seq 拉原始历史；
>      - `x.recent_contacts`：最近会话及各自最新一条消息；
>      - `ob11`：透传 OneBot 动作。
>
> - **不丢事件的保证**：
>   - 插件把事件写进本地持久队列：分段 JSONL，不做 fsync，可设容量上限。服务端不在线时就在本地积压，连上后从 `resume` 续传。
>   - 服务端先把原始事件**原样写进收件箱**（`upstream_events`），再映射入库。映射失败的事件记为 failed，暂不支持的记为 ignored，原文都保留；修好映射后，可以用 `reprocess` 重新处理。
>   - 重复的事件会被收件箱的唯一键（队列 id + 游标）和消息主键 (chat_id, seq) 两层去掉。
>   - 插件数据目录被还原、服务端反而比插件新时，服务端回 `welcome{reset}`，插件换一个新队列 id 从头重发。
>
> - **映射**：
>   - 以 NT 原始消息为准。真实 seq、md5、尺寸和文件 uuid 都在原始消息里；OneBot 消息段只用来借现成的下载链接和 @ 的 QQ 号。
>   - 每个媒体都带上 `locator`（会话、msgId、elementId 等），存进 `media_refs.locator`，以后换链接时原样交还插件。
>   - 撤回通知里的 `message_id` 只是 NapCat 的短 id，由插件补上真实 seq：先查最近见过的消息，查不到再调 `get_msg`。
>   - 未知消息元素原样保留为 `unknown` 段。
>
> - **通知适配**：
>
>   | 通知 | 存成 |
>   |---|---|
>   | 入群、退群、管理员变动、禁言、群名片、头衔、改群名、戳一戳、设精华、群文件上传、通用灰条、加好友 | **服务事件**（`chat_events`）：没有 QQ 的 seq，与消息共用会话的 `chat_pts`，经差量、历史和推送同步，客户端按时间与消息穿插显示 |
>   | 表情回应 | 合并进消息的 `reactions`，记录数量以及自己是否点过 |
>   | "对方正在输入" | 只推给在线客户端的临时事件，不存档、不占 pts |
>
>   - 群文件本身随群里的文件消息正常存档；`group_upload` 只记"谁上传了什么"。
>   - 撤回、设精华、表情回应里的 `message_id` 只是 NapCat 的短 id。插件优先用最近见过的消息或 `get_msg` 补上真实 seq；没补上的，服务端在收件箱里按短 id 找到那条消息事件来反查。
>   - 新支持某类事件后，用 `cli inbox:reprocess ignored` 重新处理以前忽略的事件，服务事件按上游事件 id 去重。
> - **对账与预热**：插件连上 3 秒后开始。
>   - 服务端没见过的会话：预热最新 200 条，默认值，可用 `UPSTREAM_WARM_MESSAGES` 配置。
>   - 落后的会话：补齐空缺，每个会话最多 1000 条；超出的部分留成缺口，交给下面的缺口补齐。
>   - 请求每秒最多 1 次，并加随机抖动。
>
> - **缺口补齐与懒回填**（`server/src/upstream/history.ts`）：
>   - 实测私聊和群聊的 seq 都是连续的，所以"会话里 [最早一条, 最新一条] 之间既没存、也没和 QQ 核对过的 seq"就是缺口。核对过的区间记在 `chats.verified_ranges`：QQ 上本来就没有的 seq（删除等）核对过一次就不再请求。
>   - 对账结束后和每 10 分钟各跑一轮：正在看的会话优先、新缺口优先，每页 50 条，每轮最多 600 次请求，剩下的下一轮接着补。
>   - 懒回填：`GetHistory` 往上翻页、翻过服务端最早一条时，现场向 QQ 拉（最多 3 次请求）；拿到空页说明到头了，记下来以后不再问。
>   - 单条消息入库失败只跳过这一条（不算核对过，下一轮重试），不再拖累整个会话。
>   - 实测（2026-10-02）：上线前 37 个群里有 48 段缺口、约 7,800 条没存；上线后按每秒约 6–7 条的速度补齐。
>   - 补齐时发现 QQ 消息里偶尔带 NUL 字符（U+0000），PostgreSQL 的 jsonb 和 text 都存不了。现在入库前统一去掉（`server/src/db/nul.ts`），收件箱原文也一样处理。
>
> - **离线时的媒体下载**：插件不在线时（例如 Mac 休眠），下载任务只推迟重试，不消耗重试次数。
>
> - **延迟统计**：每条实时消息记录两段耗时，每分钟输出一次 p50 / p95：
>   - 传输：插件入队 → 服务端收到；
>   - 入库：服务端收到 → 入库完成。
>
> - **待 P0 样本校对**：`x.history` 的分页语义，以及好友会话的 seq 是否唯一（见第 7 节 P0）。

### 4.4 领域模型与核心表
- **消息主键是 `(chat_id, seq)`**，chat 由 `(qq_account, scene, peer_id)` 确定；NT msgId 和 NapCat 短 ID 只作为辅助字段。
- **会话与消息**：
  - `chats`：会话状态（未读数、@我未读数、已读位置、置顶、通知策略、草稿），同步序号（`chat_pts`、`dialog_pts`），以及 **`verified_ranges int8multirange`**（已对账确认完整的 seq 区间）。
  - `messages`：`segments JSONB`、`text`、flags、state（normal / recalled）、reactions、`version`、`raw JSONB`。**撤回不删除原内容**。
  - 其他：`users`、`groups`、`friendships`、`group_members`、`forward_bundles`、`outbox`（`client_random_id` 唯一）、`devices`、`owner`、`tombstones`。
- **媒体**（见 4.6）：`blobs`、`blob_variants`、`media_refs`、`chat_blob_usage`、`chat_storage`、`storage_policies`。
- **通话**：`calls` 表记录方向、语音或视频、是否群通话、各阶段时间戳、结果（未接、拒绝、已接、在别处接听、忙线、失败）、时长、接听端、参与者；每通电话同时**以服务消息形式写入会话**。

### 4.5 摄取、对账与补齐
1. **每个服务端账号一条串行写入队列（单写者）**，处理顺序：
   1. 规范化消息。
   2. upsert 用户、群和会话。
   3. `INSERT … ON CONFLICT (chat_id, seq)` 合并消息。
   4. 登记媒体引用，并按需投递下载任务。
   5. 更新会话（未读数等）。
   6. 分配 `chat_pts` 和 `pts`。
   7. 发布到同步总线，并触发推送。

   单写者保证**序号分配顺序等于提交顺序**。`pts` 和 `chat_pts` 用行锁分配，锁一直持有到提交，所以将来即使有多个进程写入也成立。

   > 实现备注：
   > - 最初设计是每个 QQ 号一个写入队列，实现时改为每个服务端账号一个。原因是全局 `pts` 按账号分配，按账号串行才能保证发布顺序也等于提交顺序。
   > - **不变式**：一次写操作里只要改动了某个会话行（包括分配 `chat_pts`），提交前就统一分配新的 `dialog_pts` 并推送一次会话更新。这条由单写者集中保证（`sync/writer.ts`），各写操作不需要自己维护。它是属性测试发现的：之前撤回非顶部消息时，客户端的会话快照会和服务端不一致。
2. **空洞检测**：发现 seq 不连续就投递补齐任务；拉回之后把区间并入 `verified_ranges`。（已实现，见 4.3 实现备注"缺口补齐与懒回填"。）
3. **重连对账与主动预热**：上游重连或服务启动时，拿 QQ 的最近会话列表和本地最大 seq 比较，向前补齐。
   - 服务端**没见过的会话**，直接预热最新约 200 条。
   - 之后在后台按会话活跃度继续往前回填，限速同第 5 条。

   目标是：用户点开任何一个最近会话之前，服务端就已经有它的记录，不用临时去 QQ 拉。
4. **懒回填**（兜底）：客户端向上翻页、越过服务端已有的最早 seq 时，服务端实时去 QQ 拉取，入库后返回。只在翻到很老的历史时才会走到这里。（已实现。）
5. **深度归档**：对指定会话发起全量回溯，限速每秒不超过 1 次，并加随机抖动。

### 4.6 媒体存储：去重、共用追踪与按会话优化（重点）
- **两层模型**：
  - `blobs` 是内容：以 sha256 为主键，另存 md5、**前 10 MiB 的 md5**（QQ 大文件只给这个）、大小、类型、尺寸和时长、存储层级（热或冷）、存储位置、状态（存在或原件已清理）、引用它的会话数、最后访问时间。
  - `media_refs` 是出现记录，每在一个地方出现一次就有一行，记录：
    - 位置：chat_id、seq；如果在合并转发里，还有 forward_bundle_id 和节点路径。
    - 来源与时间：角色、发送者、时间。
    - 上游与状态：上游引用（QQ md5、fileUuid、resource_id、file_id、URL 和过期时间）、下载状态、thumbhash。

  一份内容在任意多个会话里出现，物理上**只存一份**。
- **三道去重**：
  1. **下载前**：QQ 消息元素自带 md5（大文件只有前 10MB 的 md5，要加上大小一起匹配），命中已有 blob 就直接关联，不下载。
  2. **下载后**：边下载边计算 sha256 和 md5，按 sha256 落盘到 `media/ab/cd/<sha256>`。
  3. **上传"秒传"**：iOS 先算 sha256，调用 `PrepareUpload`，服务端已有就不再上传；没有就走 tus 断点续传。发往 QQ 时复用同一个 blob。
- **共用追踪与跳转**：
  - `ListMediaUsages(blob)` 返回所有出处（会话、seq、时间、发送者，以及合并转发里的节点路径）。
  - 客户端在媒体查看器里显示"出现在 N 个聊天"，点击后用 `GetHistory(anchor=seq)` 定位并高亮原消息；如果媒体在合并转发里，先展开外层消息，再进入对应节点。
- **按会话的占用统计**：
  - `chat_blob_usage(chat_id, sha256, ref_count)` 记录"会话—媒体"的去重关联；`blobs.ref_chats` 记录有多少个会话引用了这个媒体。
  - `chat_storage` 记录三个量：
    - **逻辑占用**：本会话引用的所有不同媒体的大小之和。
    - **独占占用**：只被本会话引用的媒体之和，也就是清理这个会话能真正腾出的空间。
    - **共享占用**：逻辑占用减去独占占用。
  - 在单写者中增量维护，每晚全量重算一次校正；全局还统计物理总占用、去重节省的空间和去重命中率。
- **策略**（三层：全局默认 → 按会话类型 → 单个会话）：
  - 自动下载：按类型和大小上限，默认 ≤ 200MB 自动下载。
  - 原件保留期：永久、N 天、仅保留缩略图三种。
  - 可选：过期后有损重压缩，默认关闭。
  - 冷存储：N 天没有访问就迁到冷存储。
  - **一个媒体最终采用的策略，取所有引用它的会话里保留最久的那个**。GC 只删除"所有引用方都允许删除"的原件，并保留缩略图和预览版本。
- **冷热分层**：`StorageBackend` 接口，热存储用本地磁盘，冷存储可以接任意 S3 兼容存储。

  > 实现备注（2026-10-04，`server/src/media/tiering.ts`）：
  > - 冷存储目前是另一块本地磁盘（`MEDIA_COLD_ROOT`，例如廉价大硬盘），与热存储同一个 `StorageBackend` 接口，以后换 S3 一类只需加一个实现。没配置时不分层。
  > - 只移动原件。缩略图、预览图、头像始终在热存储，列表靠它们秒开。视频的 faststart 版本和原件一样大，跟着原件走。
  > - 下沉规则，每天跑一次，也可以用 `RunTiering` 预估或立即执行：
  >   1. **按时间**：原件多久没被访问（从没访问过按入库时间）超过 `cold_after_days`（默认 180 天），并且不小于 `cold_min_bytes`（默认 1 MiB）。一份内容被多个会话引用时取最保守的规则：任一会话设了"永不下沉"就不动，天数和大小门槛取最大值。
  >   2. **按会话配额**：会话独占的原件在热存储里超过 `hot_quota_bytes`，最久没访问的先下沉。
  >   3. **按全局配额**：账号热存储总量超过全局 `hot_quota_bytes`，同样按最久没访问先下沉。
  > - **访问跟踪**：每次下载原件记一次访问（同一内容 10 分钟内只算一次）。冷存储里的原件累计被打开 3 次就提回热存储。
  > - **移动顺序**：在 blobs 行锁内先写进目标层（按 sha256 校验）、改记录，提交后才删源文件。中途出错最多留下一份多余的文件，不会丢内容。冷存储里的内容被重新下载时，不会在热存储里再存一份。
  > - **外接硬盘**（实际部署：`/Volumes/HDD-1/qqbridge-cold`）：
  >   - **判断盘在不在**：冷存储根目录里有 `.qqbridge-storage` 标记才算挂上。服务端永远不创建根目录本身，因为盘没挂上时 `/Volumes/<盘名>` 下的路径会落到系统盘上。
  >   - **盘不在时**：不下沉也不提回。下载接口读到冷存储里的内容，当场经插件向 QQ 换链接重新下载，按 sha256 校验后放进热存储（同一内容同时只取一次），不改消息里的媒体状态。QQ 也拿不到时返回 410，原因区分"QQ 不在线"和"已拿不到"，客户端显示为已过期。
  >   - **盘回来后**：每天的分层任务先清理盘上的孤儿文件（盘不在期间被取回到热存储的内容，以及已清理的原件），只删超过 1 小时没动过的文件。
- **处理与下发**：生成缩略图（约 320px）、预览图（约 1280px）和 thumbhash；语音转成 AAC 并生成波形；视频生成封面并做 faststart。下发支持 Range 和 ETag，URL 使用短期 HMAC 签名。
- **管理界面**：存储统计页（会话按逻辑或独占占用排序，并按类型拆分）；"按条件清理"执行前先预估能释放多少空间（只计算独占部分）。

  > 实现备注：`GetStorageOverview` 给出冷热两层的总量和每个会话的冷热分布；`GetChatStorage` 给出单个会话按类型的拆分（逻辑 / 独占 / 冷热 / 已清理数量）、最大的内容（是否与其他会话共用、最后访问时间、第一次出现在哪条消息），以及最终生效的全部策略（保留期、自动下载上限、下沉天数、大小门槛、热存储配额），客户端据此做"存储管理"页和按会话配置。

> **实现备注：媒体下载任务**（`server/src/media/fetcher.ts`）
> - **流程**：
>   1. 用 `FOR UPDATE SKIP LOCKED` 认领待下载的引用，多个下载者不会拿到同一条。
>   2. 按三层策略检查自动下载上限，依次看 QQ 声明的大小、`Content-Length`、下载过程中实际累计的字节数，任一处超限就放弃。
>   3. 边下载边计算哈希，按 sha256 去重落盘。
>   4. 图片生成缩略图（320px）、预览图（1280px）和 thumbhash。
>   5. 通过单写者更新消息里的媒体段，客户端经 `chat_pts` 收到"媒体已就绪"。
> - **状态**：
>
>   | 状态 | 含义 |
>   |---|---|
>   | `pending` | 等待下载 |
>   | `fetching` | 下载中。进程重启时由 `recover()` 放回 `pending` |
>   | `stored` | 已下载 |
>   | `failed` 且 `next_attempt_at` 不为空 | 等待重试，按指数退避加抖动；客户端看到的仍是"下载中" |
>   | `failed` 且 `next_attempt_at` 为空 | 超过最大次数，已放弃 |
>   | `expired` | 链接失效，向上游换一次新链接后仍然拿不到 |
>   | `skipped` | 超过自动下载上限 |
> - **换新链接**：`MediaSource` 接口负责。上游适配器提供 refresher，NapCat 上对应插件的 `x.media_url`；没有接入上游时，链接过期的媒体直接记为 `expired`。
> - **派生版本**：缩略图和预览图本身也是 blob，用 `blob_variants` 关联到原件，同一内容只处理一次。之后同一内容再次出现，无论是 sha256 相同还是 QQ md5 在入库时命中，都直接带上已有的缩略图信息。
> - **派生版本的统计与签名**：
>   - 派生版本不计入 `chat_blob_usage` 和会话占用统计，占比很小；它们跟随原件，GC 清理原件时保留。
>   - `SignMediaUrls` 只为"账号自己会话里的原件"及其派生版本签发链接。

> **实现备注：派生版本与类型识别**（`server/src/media/processing.ts`、`sniff.ts`）
> - **类型以文件头为准**：QQ 下载接口给的 Content-Type 经常不对，实测视频是 `application/octet-stream`，AMR 语音标成 `audio/mp3`。iPhone 的播放器靠类型解码，所以入库时按文件头识别，识别结果优先，顺带纠正旧数据。
> - **图片 / 表情**：320px 缩略图、1280px 预览图、thumbhash。手机时间线只拉缩略图（约 20KB），原件按需下载。
> - **语音**：实测 QQ 语音既有 silk 也有 AMR，iPhone 都不能原生播放。
>   - 服务端保留原件，另转一份 AAC（m4a，32kbps，faststart）作为 `playable` 派生版本。silk 用 silk-wasm 解码，AMR 等用 ffmpeg 解码。
>   - 同时算出 64 段波形（`blobs.waveform`），随消息下发，气泡不用下载音频就能画出来。
>   - mp3、m4a 这类本身能播放的不转码。
> - **视频**：
>   - **封面**：用 ffmpeg 取一帧，同样产出缩略图、预览图和 thumbhash，宽高即视频宽高。聊天列表里只显示封面，滑动时不用为每个视频建播放器、发请求；点开才开始流式播放。
>   - **流式播放（faststart）**：实测 QQ 视频的索引（moov）在文件末尾。虽然服务端支持 Range，但播放器得先跳到文件尾取索引再回头播，起播慢。所以另存一份 `playable` 派生版本：`-c copy -movflags +faststart`，只换封装、不重新编码，画质和大小基本不变。原件保留不动（md5 去重要用原件）。本来就是 faststart 的视频，`playable` 直接指向原件，不额外占空间。
>   - 实测：25 个视频里 12 个本来就是 faststart；13 个做了转封装，多占约 91MB。客户端播放时优先用 `playable_sha256`。
> - **处理时机**：下载完成和上传完成时都会处理。发出去的媒体经 QQ 回到会话时按 md5 复用，派生版本已经就绪。
> - **补处理**：已存档的内容用 `cli media:reprocess` 补；没有 ffmpeg 时语音转码和视频封面跳过，不影响存档。

> **实现备注：上传**（`server/src/media/upload.ts`）
> - **秒传**：客户端先调 `PrepareUpload`，服务端已有这份内容就直接返回。
> - **续传**：没有就按 tus 1.0 核心协议上传，`HEAD` 查进度，`PATCH` 续传。
>   - 同一账号的同一份内容只有一个进行中的上传；App 重启后再调 `PrepareUpload`，会拿到同一个地址和已上传的进度。
>   - 连接中途断开时，已收到的部分照样保留。
>   - 进程崩溃后，按数据库记录的进度截断临时文件。
> - **校验**：传完校验 sha256，不一致返回 460 并作废这次上传。超过 24 小时没有进展的上传会被清理。

> **实现备注：原件清理**（`server/src/media/cleanup.ts`、`policies.ts`、`accounting.ts`）
> - **统计口径**：会话占用只计**原件还在**的内容。原件被清理时，所有引用它的会话的逻辑、独占占用和数量一起扣减；同样的内容重新下载回来时再加回去（`setBlobPresence`）。属性测试的随机操作里包含清理和恢复。
> - **并发**：存入采用两阶段：先写临时文件算出哈希，再在 `blobs` 行锁内放进存储。清理原件时，也是在同一把行锁内先改状态、再删文件，两者互斥，不会出现"刚下载回来又被删掉"。
> - **执行条件**：
>   - 手动清理（`ExecuteCleanup`）把选中的出现标记为不再需要原件（`keep_original = false`）。
>   - 定时清理每天跑一次，把超过保留期的出现视为不再需要原件。
>   - 两种情况都按"保留最久者优先"判断，只有所有引用方都不需要时才删除原件。
>   - 发件箱里待发送的内容不删；缩略图和预览图不删。
> - **对客户端**：被清理内容所在的消息，媒体状态变为 `purged`（经 `chat_pts` 推送），客户端可以提示"原图已清理"；内容重新下载回来时恢复为 `stored`。
> - **策略按字段继承**：`keep_original_days` 和 `auto_fetch_max_bytes` 各自继承，单独调某个会话的自动下载上限，不会改掉它的保留期。
>
>   | `keep_original_days` | 含义 |
>   |---|---|
>   | null | 继承上一层（全局层也没设 = 永久） |
>   | -1 | 显式永久 |
>   | 0 | 只保留缩略图和预览图 |
>   | N | 保留 N 天 |

### 4.7 类 Telegram 同步模型
- **两级序号**：全局 `pts` 记录会话列表和资料层面的变化；每个会话独立的 `chat_pts` 记录消息的新增和变更，包括撤回、回应、媒体就绪、通话记录。
- **版本化行**：每一行记录最后一次变更时的序号，差量查询就是取"版本号大于客户端游标"的行的最新状态；删除用墓碑记录。
- **`Subscribe(from_pts)`**：先回放差量，再推送实时更新；实现顺序是先挂监听、再计算差量、最后冲刷缓冲，保证不漏不重。
- **客户端规则**：收到 `local + 1 == pts` 就直接应用；发现空洞时等 0.5 秒，再调用 `GetDifference` 或 `GetChatDifference`；差量过大时返回 TooLong，客户端重置该会话窗口。
- **发送幂等**：用 `client_random_id` 保证重试不重复；已读状态会回写 QQ。
  > **实现备注：发送**（`server/src/outbox/*`、插件 `upstream/sender.ts`）
  > - **入队**：`SendMessage` 先把消息放进发件箱并立即返回。
  >   - (账号, `client_random_id`) 唯一，重复提交返回同一个条目；已失败的条目重提即重试。
  >   - 媒体只引用 sha256，发送前要求已经上传。
  > - **同步**：发件箱条目按全局 pts 同步（`Difference.outbox` 和 `OutboxUpdate`），所有设备都能看到"发送中 / 已发送 / 失败"。全新设备只会收到还没发送成功的条目。
  > - **发送任务**：经插件的 `x.send` 发出。
  >   - 同一会话严格按顺序发送。
  >   - QQ 不在线时等待，不消耗重试次数。
  >   - 超时会重试：插件按 `client_random_id` 去重，进行中的请求共用同一个结果，已完成的落盘保留，插件重启后也不会发出第二条。
  >   - QQ 明确拒绝时直接判为失败。
  > - **媒体**：交给 NapCat 的是带签名、带文件名的下载链接（`/media/<sha256>/<文件名>`），NapCat 下载后再传给 QQ。
  > - **回复**：直接使用真实 seq。
  > - **对上已发出的消息**：发送成功后，条目里记下消息的 seq。消息本身由 QQ 的 `message_sent` 事件正常入库并经 `chat_pts` 推送，两者到达的先后不固定，客户端按 (chat_id, seq) 对上。
  > - **撤回**（`RecallMessage`）：经插件的 `x.recall` 发起，结果以 QQ 的撤回通知为准。
  > - **已读回写**：经 `mark_*_as_read` 写回 QQ，尽力而为，QQ 不在线就跳过。
- **通话信令**（振铃、接通、挂断）走 `Subscribe` 流里的**临时事件**，不占 pts；**通话记录**是持久化的消息，走 `chat_pts`。
- **切换会话不等待：数据要在点开之前就到手机上**。
  - 在前台时，`Subscribe` 会推送**所有会话**的新消息，客户端收到就写进本地库。
  - 离线后追平时，`GetDifference` 只返回"哪些会话变了"。客户端随即用 **`GetChatDifferences`** 一次拉取多个会话的"首屏"：变化的消息，或最新 30 条；超过一屏就给最新一屏并标 `too_long`，客户端按空洞处理。
  - 服务端的单会话查询走 (chat_id, seq) 和 version 索引，不到 1ms，所以真正要省掉的是网络往返。预取策略见 6.2。
- **当前会话的实时性**：

  | 环节 | 做法 | 预计耗时 |
  |---|---|---|
  | QQ → NapCat | NapCat 本身就是一个 QQ 电脑端，和官方客户端走同一条推送通道 | 与官方一致 |
  | 插件 → 服务端 | 常驻 WebSocket，事件到达立即推送；先写本地队列，保证不丢 | < 5ms |
  | 服务端处理 | 写收件箱 → 映射 → 单写者小事务入库 → 提交后立即发布 | 目标 < 20ms |
  | 服务端 → iPhone | `Subscribe` 长连接主动推送，不轮询 | Tailscale 直连约 10–30ms，走中继约 50–150ms |
  | iPhone 显示 | 写本地库，列表只刷新变化的部分 | < 20ms |

  - **文字不等媒体**：消息先推送，带宽高，界面可以先占位；缩略图和 thumbhash 生成后，再以"媒体就绪"推送一次。
  - **不被积压拖慢**：实时消息每条一个小事务；批量回填拆成小批，优先级更低。媒体下载按"正在看的会话（`SetActiveChat`）优先，其次新的优先"排队。
  - **断线**：长连接带心跳，客户端发现断开、或网络切换时立即重连，并从 pts 补差量。
  - **App 在后台**：长连接断开后靠 APNs；通知扩展同时把消息写进 App Group 里的本地库。
  - **可观测**：上游链路记录每条消息的接收、提交、推送时间，统计服务端内部延迟；iOS 调试面板显示端到端延迟。

### 4.8 客户端 API（Protobuf / ConnectRPC，包名 `qqbridge.v1`）
- **AuthService**：Login / Logout / ListDevices / RevokeDevice / RegisterPush（同时登记 alert 推送和 VoIP 推送的 token）。
- **SyncService**：GetState / GetDifference / Subscribe（服务端流）/ GetChatDifference / GetChatDifferences（批量首屏，用于预取）。
- **DialogService**：ListDialogs / SetPinned / SetNotifyPolicy（default / all / mentions / muted）/ SaveDraft（多设备同步）/ MarkRead（回写 QQ）/ SetTyping / SetActiveChat（正在看的会话，媒体优先下载）。
- **MessageService**：GetHistory（支持按 anchor 定位）/ SendMessage（发件箱，幂等）/ RecallMessage / SearchMessages（全文搜索）/ GetMessages / React / GetForward / ListSharedMedia。
- **MediaService**：PrepareUpload（秒传 + tus 续传地址）/ SignMediaUrls / ListMediaUsages / GetStorageOverview / PlanCleanup / ExecuteCleanup / List、Set、DeleteStoragePolicy。

> 已实现：Auth（Login / Logout / ListDevices）、Sync 全部、Dialog（除 SetTyping）、Message（GetHistory / SendMessage / RecallMessage / SearchMessages）、Media（以上全部）。其余待做。
- **CallService**：StartCall / AnswerCall / DeclineCall / Hangup / JoinGroupCall / SetMute / ListCalls / GetActiveCall；应答和发起时返回 LiveKit 的房间名和短期令牌。
- **ContactService** 和 **AdminService**：QQ 登录状态、扫码登录中转、补齐任务、通话桥健康状态（包括 AV Host、PulseAudio、网关）。

  > 实现备注（2026-10-04）：
  > - **MessageService** 新增：
  >   - `React`：只有群聊支持，结果立即写进消息，QQ 的回应通知随后用准确总数覆盖。
  >   - `GetForward`：合并转发第一次打开时经插件 `getMultiMsg` 拉取，缓存进 `forward_bundles`；节点里的媒体照常去重、下载、计入会话占用；嵌套的合并转发按 path 逐层展开。
  >   - `ListSharedMedia`：按消息分页，默认不含表情包。
  > - **DialogService** 新增 `SetTyping`：只有私聊支持，每个会话 4 秒最多一次。
  > - **AuthService** 新增 `RegisterPush`：登记 APNs 普通推送和 VoIP 推送的令牌，推送本身还没做。
  > - **ContactService**（`server/src/contacts/`）：**不在后台逐个爬取资料**（风控风险高），只在需要时取。
  >   - 好友列表、群列表各一次请求就能拿全，建成索引；上游连上后和之后每天各刷新一次，也可手动触发。被删的好友标记为非好友。
  >   - 头像：打开会话（`SetActiveChat`）时检查，超过一天没检查过才下载一次；直接从 QQ 头像服务取，不经 QQ 协议。
  >   - 详细资料（签名、性别等级、群简介、群成员）：打开资料页时请求（`refresh = true`，缓存超过 10 分钟才当场刷新）。
  >   - 头像按内容去重存储，内容变了才更新，并经 pts 推给客户端。
  >   - 2026-10-04 起改成这样。最初做过"最近 30 天有往来的人每 7 天自动刷新资料"，按用户要求去掉了。
  > - **AdminService**（`server/src/admin/`）：
  >   - `GetStatus`：QQ 是否在线和插件版本、收件箱积压与失败、存档缺口、下载与发件队列、通话桥（引擎登录、暂停原因、网关、进行中的通话）、冷热存储。
  >   - `GetQqLogin` / `RefreshQqLoginQrcode`：经 NapCat WebUI 中转扫码登录，返回二维码内容，客户端自己画成二维码。
  >   - `ListArchiveStatus`：每个会话的缺口数、最早一条、是否已补到历史开头。
  >   - `SetDeepArchive`：深度归档，从 seq 1 补起，直到 QQ 说没有更早的，排在普通缺口之后。
  >   - `FillHolesNow`：立即跑一轮缺口补齐。
  > - **缺口补齐的两处修正**（真实数据上发现）：
  >   - QQ 返回 2004000（no any more msg）表示"没有更早的了"，现在按到头处理，不再当成错误。
  >   - 某个会话出错只跳过这个会话，不再让整轮补齐中断。之前一个会话连续出错，导致其他会话的缺口两天没补。
- **HTTP 端点**：`/media/*`、`/upload`（tus）、`/assets/*`。

### 4.9 推送（APNs）
- **消息**：私聊默认全部推送，群聊默认只推 @我和回复我的消息；推送带 `mutable-content`，由 NSE 用 Communication Notifications 显示头像，并支持快捷回复；P4 起对推送内容加密。
- **来电**：
  - 能用 CallKit 时：PushKit VoIP 推送 → `reportNewIncomingCall` → 系统原生来电界面。
  - CallKit 受限时：时效性通知加约 30 秒铃声，点击进入 App 内的来电界面。
  - 主叫取消，或在手机官方 QQ 上接听后，服务端推送"结束"，撤掉 iPhone 上的来电提示。

### 4.10 检索、认证与安全
- **检索**：PGroonga 中文 N-gram 索引，支持过滤和高亮。
  > **实现备注**（`server/src/search/messages.ts`）：
  > - **语法**：`&@~` 查询语法，支持多词同时出现、`OR`、`-排除`；语法写错时按普通文本重搜。
  > - **过滤**：可按会话、发送者、内容类型（MessageFlag 位）、时间范围过滤。
  > - **排序与分页**：按时间倒序，以 (time, chat_id, seq) 为游标分页。
  > - **高亮与范围**：返回从查询中提取的关键词，供客户端高亮；撤回的消息也能搜到。
- **认证**：只有一个所有者账号（argon2id）；每台设备一个令牌，库里只存哈希，可以吊销。
- **网络**：推荐 Tailscale。插件和 AV Host 的控制接口只监听回环地址，并要求 token；LiveKit 令牌只给所有者设备签发，单次通话有效。
- **数据**：定期备份（pg_dump + restic），磁盘加密。

### 4.11 部署（分两个阶段，用同一份 compose）
- **服务清单**：
  - `qq`：基于 `mlikiowa/napcat-docker`（Shell 模式），加入隔离的 PulseAudio 和 supervisord，管理 Xvfb、PulseAudio、NapCat 和 AV Host 四个进程。在构建镜像时就写入带开关、可还原的 `loadNapCat.js` 分流，并**锁定 QQ 和 NapCat 的版本**。沿用官方镜像的反容器检测处理。
  - `call-gateway`：用 `network_mode: service:qq` 共享回环网络，挂载 Pulse socket 和 X socket。
  - `server`：本项目服务端。
  - `postgres`：pgroonga 镜像。
  - `livekit`：单端口 UDP 复用，自带 TURN。
  - `tailscale`：对外访问。
- **阶段 A（现在：只有这台 MacBook）**：
  - 全部服务跑在 OrbStack 里，QQ 容器用 **arm64** 镜像（需要先确认 arm64 版 QQ 里带有 `libAVSDKPlugin.so`）。
  - iPhone 通过 Tailscale 访问 Mac，LiveKit 的 `rtc.node_ip` 设为 Mac 的 Tailscale IP。
    - OrbStack 的 Docker 引擎跑在虚拟机里，端口只能绑 `0.0.0.0` 或 `127.0.0.1`，不能只绑 Tailscale IP（入会仍然需要令牌）。
    - 网关容器也是经这个 IP 绕回 Mac 再连上 LiveKit 的，实测可行。
    - 到阶段 B 的 Linux 主机上，就可以只对 tailnet 开放端口。
  - 限制：
    - Mac 休眠时 QQ 离线：消息靠对账补回，通话会漏接。验证期间接上电源并开启防休眠。
    - OrbStack 大概率无法加载 v4l2loopback，所以发送 iPhone 摄像头画面放到阶段 B。
  - 资源：Shell 模式加 AV Host 比完整图形界面更轻，一共约 1–2GB 内存。
- **阶段 B（之后：有常开主机）**：推荐 x86_64 Linux 迷你主机，同一份 compose 直接迁过去；在宿主机加载 v4l2loopback 后补齐摄像头画面的发送。如果到时候用 Windows 或 Mac mini，见 5.8。

## 5. 音视频通话桥接（只针对 NapCat，基于 maibot 的已验证方案扩展）

### 5.1 原理
```
腾讯信令 ⇄ QQ 内核（wrapper.node，NapCat 进程）
              ⇅ addKernelAVSDKListener / setActionFromAVSDK
          napcat-plugin-qqbridge 通话模块 ⇄ HTTP（仅回环地址 + token）⇄ AV Host
                                                                          ⇅ embed.postMessage({cmd,id,param})
                                                          libAVSDKPlugin.so（NTRTC，独立插件进程）
                                                                          ⇅ 媒体直接连腾讯服务器
                                                          PulseAudio：qq_speaker（对方声音）/ qq_mic（我方声音）
```
- 信令走内核，由插件转发；媒体由 AVSDK 插件自己连腾讯服务器收发。
- 我们只在 PulseAudio 和窗口画面这两个"设备边界"上接入 LiveKit。不模拟点击，不逆向网络协议。

### 5.2 组件职责

| 组件 | 职责 |
|---|---|
| 插件通话模块 | 内核监听；转发内核数据（指令 55）；把 AV Host 输出交回内核（输出 20001 → `setActionFromAVSDK`）。识别来电（输出 20006）、接听结果（输出 5）、进入房间也就是已接通（输出 20004）、结束（内核回调 `onS2CActionToAVSDK` 带 destroyReason）、需要重新登录（输出 20050 / 120043）。从 uid 解析出来电者的 QQ 号和昵称。**按服务端指令**执行接听、拒绝、挂断、拨打、加入群通话、静音。 |
| AV Host | 用 QQ 自带的 Electron 加载 AVSDK（`--register-pepper-plugins`），设置 `--disable-gpu`、`--no-sandbox`；用 supervisord 守护，崩溃自动重启。v1 只有隐藏窗口；做视频时让窗口在 Xvfb 上显示，把 embed 设为 1280×720。 |
| PulseAudio | `qq_speaker` 是 null-sink，设为默认扬声器；`qq_mic` 是 null-sink，再用 remap-source 映射成 `qq_mic_source`，设为默认麦克风。通过 unix socket 只在容器内访问。<br>**实现备注**：null-sink 在没人要求低延迟时按 2 秒为一块渲染，实测会让链路时快时慢地多出 1 秒以上。所以 QQ 容器里常驻两个 10ms 的录音流（`pulse-anchor`），把两个声卡钉在 10ms。 |
| call-gateway | 用 `@livekit/rtc-node` 以"QQ 端"身份加入房间：<br>· 语音：`parec qq_speaker.monitor` → AudioSource；订阅 iPhone 音频 → `pacat qq_mic`。<br>· 视频（5.5）：x11grab 截取 AV Host 窗口 → VideoSource；订阅 iPhone 视频 → v4l2loopback。 |
| server 的 CallService | 维护通话状态机（同一时间只有一通活动通话）；建房间、签发令牌；协调插件和网关；推送来电；写入通话记录。 |
| iOS | LiveKit Swift SDK；CallKit 或 App 内来电界面；AVAudioSession 设为 voiceChat 模式（带回声消除）。 |

### 5.3 指令表：已知的和待录制的
- **已知**（来自 maibot，已在 Linux QQ 上验证）：

  | 方向 | 指令 | 含义 |
  |---|---|---|
  | 发给 AVSDK | 1 | 登录：`[selfUid, selfUin, selfUin, accountPath, ""]` |
  | 发给 AVSDK | 5 | 接听：参数由来电数组重排得到，见 `buildAcceptParams` |
  | 发给 AVSDK | 55 | 转发内核数据 |
  | AVSDK 输出 | 20001 | 网络数据，要交回内核 |
  | AVSDK 输出 | 20006 | 来电详情 |
  | AVSDK 输出 | 5 | 接听结果 |
  | AVSDK 输出 | 20004 | 进入房间，即已接通 |
  | AVSDK 输出 | 20050 / 120043 | 需要重新登录 |
- **待录制**：拒绝或忽略、挂断（quit / close / clearRoom）、开关麦克风（openMic / closeMic）、主动拨打（startCall / invite，以及内核侧怎么发起）、群通话（内核回调 `onGroupVideoActionToAVSDK` 和 `onGroupVideoServerPushToAVSDK`，以及加入和退出）、视频（开关摄像头、订阅对方画面）。
- **录制方法**：
  1. 在 `qq-gui-lab`（有头 QQ + NapCat Framework + noVNC）里，挂钩通话窗口里 embed 的 `postMessage` 和 `message` 事件，同时挂钩内核 AVSDK 监听器。
  2. 用测试号把每个动作操作一遍，记录完整的指令序列，存到 `fixtures/avsdk/`（脱敏）。
  3. 在 AV Host 里按录制结果实现，并做成回放测试。

### 5.4 呼叫流程
- **QQ 来电**：
  1. 插件收到来电（内核来电回调和输出 20006），状态变为振铃，上报服务端。
  2. 服务端建房间，推送 VoIP 推送或时效性通知。
  3. iPhone 接听：
     1. 客户端入会。
     2. 网关拉起两条 PulseAudio 管道。
     3. 插件发指令 5 接听。
     4. 收到输出 20004，状态变为已接通，计时开始。
  4. iPhone 拒接时，发送录制得到的拒绝指令。
- **对方取消，或在手机官方 QQ 上接听**：插件收到结束回调，服务端撤掉 iPhone 上的振铃，记一条"未接"或"已在其他设备接听"。
- **App 内发起**：`StartCall` → 插件按录制的序列发起（内核侧 + AVSDK）→ 振铃 → 接通。
- **群语音**：插件上报群通话开始；App 在群聊顶部显示"加入群通话"，点击后执行 `JoinGroupCall`。QQ 把所有成员的声音混成一路从 qq_speaker 输出，我们转发这一路混音；v1 显示参与人数和名单。
- **挂断**：任一方挂断后，插件发挂断指令，网关拆除管道，服务端写入通话记录（服务消息）。

### 5.5 视频
- **收看对方画面**（阶段 A 可测）：让 AV Host 窗口在 Xvfb 上显示，AVSDK 在禁用 GPU 时会把画面软件渲染到 embed 里；网关用 x11grab 截取窗口区域，720p、25fps。也可以试试 Electron 离屏渲染的 `paint` 事件能不能直接拿到包含插件内容的帧。
- **发送 iPhone 摄像头画面**（阶段 B）：iPhone 视频 → ffmpeg → v4l2loopback 虚拟摄像头（`QQBridgeCam`），再用录制得到的指令让 AVSDK 选用这个设备。
- 如果视频始终做不通，就保持语音桥接，视频继续研究。

### 5.6 预期质量
- **语音**：只经过 PulseAudio 回环加 WebRTC，额外延迟预计 100–250ms。
  - **实测**（2026-10-01，阶段 A，不含 QQ 本身）：假 iPhone ⇄ LiveKit ⇄ 网关容器 ⇄ PulseAudio 回环，往返 190–222ms，单向约 100ms，零丢帧。用 `tools/call-e2e.sh` 可以复现。
  - 网关两个方向都按挂钟限速、超额就丢帧：管道和 pacat 里的积压在两端都按实时速度进出时会变成永久延迟，实测曾因此多出约 400ms。
- **视频**：截取窗口再编码，额外延迟约 200–400ms，画质低于原生通话。
- **回声**：iPhone 端负责回声消除；QQ 侧的输入和输出是两个独立的虚拟设备，不形成声学回路。

### 5.7 可行性闸门（P0-C，任一项不过就降级，不阻塞其他工作）
- **G1**：在 OrbStack（arm64）里**复现 maibot 桥**：NapCat Shell + AV Host + PulseAudio。测试号打进来以后：
  - 能自动接听；
  - 在 qq_speaker 上录到对方的声音；
  - 往 qq_mic 注入测试音，对方能听到。
  - 不通过时：在 x86_64 机器上复现，例如临时的云主机；排查 arm64 版 AVSDK 的问题。
- **G2**：**指令录制**：在 `qq-gui-lab` 里拿到拒绝、挂断、静音、主动拨打的指令序列，并能在 AV Host 里重放成功。
- **G3**：群语音：能加入群通话，双向有声。
- **G4**：视频：收看对方画面能稳定截取（阶段 A）；发送摄像头画面需要阶段 B 的 Linux 主机，或者 OrbStack 能加载 v4l2loopback。
- **G5**：端到端：iPhone 通过 LiveKit 与 QQ 用户双向通话，语音额外延迟 < 250ms，连续 30 分钟稳定。
  - 进展：除 QQ 本身以外的整条媒体链路已经实测通过（单向约 100ms，见 5.6）。剩下的是 AVSDK ⇄ PulseAudio 这一段，要等 G1 登录后验证。
- **实测记录（2026-10-02，主号）**：
  - 插件第一次在真机上运行时，通话引擎反复输出 cmd 20050。原实现把 20050 当成"需要重新登录"，立即重登，于是陷入死循环：约 2 分钟内提交 775 次登录，引擎输出 11991 次 20050。
  - 采样显示每次登录其实都成功了（有 cmd 1 的结果返回），所以 20050 很可能不是"需要重登"，而是设备变化之类的通知。具体含义留待 G1 抓取负载后确认。
  - **2026-10-04 确认**：20050 是通话引擎自己的运行日志（一行文本，以 `avsdk output(wrapper):` 开头），与登录无关；登录结果（输出 1）每次都是 `[0, ""]`。现在 20050 只写进 `capture/avsdk-log-*.jsonl`，不再触发重登，死循环消失（重载后只登录 1 次）。输出 20061 是设备列表，引擎已认出 `QQBridge_Speaker` 和 `QQBridge_Microphone`。
- **G1 实测（2026-10-04，主号，arm64 / OrbStack）**：
  - 另一个 QQ 号打语音电话进来：插件识别来电（含来电者 QQ 号和昵称）→ 经插件接口接听 → 0.2 秒内接通（输出 20004）。
  - **收**：从 `qq_speaker.monitor` 录到了对方的声音（接通约 3 秒后开始有声，平均约 -20 dB）。
  - 对方挂断后，内核回调把状态置为 ended（endReason 1）。
  - **发**：往 `qq_mic` 放每秒一声的提示音，对方确认听到了。
  - **结论：G1 通过**，在 arm64（OrbStack）上不需要 x86_64 主机。
- **G5 实现（2026-10-04）**：
  - 插件：通话桥每次状态变化都作为 `qqbridge_call` 事件进上游队列；新增 RPC `x.call.accept`、`x.call.current`。
  - 服务端 `server/src/calls/`：`calls` 表记录每通来电；状态经 Subscribe 的 `CallUpdate` 推给在线设备（临时事件）；结束时在与对方的私聊里留一条 kind = `call` 的服务事件（接通与否、时长、是否经本系统接听）。服务端离线期间积压、超过 2 分钟的振铃直接记为结束。
  - 接听顺序：`CallService.AnswerCall` → 签发两个 LiveKit 令牌 → 网关先入会 → 再让插件接听 → 把客户端令牌和地址交回。这样 QQ 一接通，对方的声音就已经有地方去了。
  - 网关改为常驻（`call-gateway serve`，控制接口 127.0.0.1:6120，口令 `CALL_GATEWAY_TOKEN`）。同一时间只桥接一个房间，重复的入会请求直接忽略。
  - 网络：LiveKit 信令端口 7880 只开在回环上，客户端经 `tailscale serve` 的 HTTPS（7443）访问；媒体端口 7881/7882 必须让手机直连，所以开在 0.0.0.0（OrbStack 只能这样绑定），ICE 凭据由信令下发。
  - 测试页 `/lab/call`（`CALL_LAB=1`）：手机浏览器登录后轮询来电，点"接听"即可在网页里通话。浏览器只在 HTTPS 下允许用麦克风，所以要经 Tailscale HTTPS 打开。
  - 还没有的：拒接、挂断、静音、主动拨打（等 G2 录指令）。客户端离开房间不会挂断 QQ 那边。
  - 已采取的措施：
    - 重登录加退避（5s 起翻倍），10 分钟内超过 3 次就暂停通话桥；
    - 通话桥改为由 `QQBRIDGE_CALLS` 开启，**默认关闭**，关闭时 AV Host 也不启动。
    - 开关也可以在运行时改：`tools/qq-plugin.sh calls on|off` 写开关文件并经 NapCat WebUI 重载插件，QQ 不用重新登录（2026-10-02 实测插件重载约 1 秒，上游链路随即重连）。
- **降级路径**：
  - G1 不通过：只做"来电提醒 + 一键跳转官方 QQ + 通话记录"。
  - G2 不完整：先上线"仅能接听来电"的版本。
  - G3 或 G4 不通过：先上线 1:1 语音。

### 5.8 平台适配层（以后换主机系统时用）
maibot 的方案只在 Linux 上验证过。Windows 和 macOS 版 QQ 的 AVSDK 插件形态不同（DLL / dylib），要重新验证 AV Host 怎么加载，以及虚拟设备方案：Windows 用 VB-CABLE、softcam、Windows Graphics Capture；macOS 用 BlackHole、Camera Extension、ScreenCaptureKit。call-gateway 里跟 LiveKit 打交道的部分各平台通用。**现阶段只做 Linux**。

## 6. iOS 客户端设计（自研，iOS 27）

### 6.1 技术栈
- 只支持 iOS 27；Swift 6，开启严格并发检查。
- 界面：SwiftUI 搭整体框架，聊天记录用 UIKit 的 `UICollectionView`，单元格用 `UIHostingConfiguration` 渲染。
- 网络：connect-swift + swift-protobuf。
- 本地库：GRDB，放在 App Group 里。
- 媒体：Nuke、AVFoundation、QuickLook。
- 通话：LiveKit Swift SDK、CallKit、PushKit。
- 扩展：NotificationService、Share。

### 6.2 架构
- **`SyncEngine`**（actor）：负责连接、`Subscribe` 流、pts、补洞，也接收通话信令。
- **`Store`**（GRDB）：每个会话维护"已加载连续区间 + 空洞"。
- **`Prefetcher`**：保证切换会话时直接读本地，不出现转圈。
  - **启动、回到前台、重连后**：`GetDifference` 拿到变化的会话，按置顶、有未读、最近活跃、常用排序，用 `GetChatDifferences` 每次批量拉 50–100 个会话的首屏；再预取这些首屏里的缩略图（受缓存上限和网络类型约束）。
  - **首次登录**（本地为空）：拉会话列表，再拉前 100 个会话的首屏。
  - **会话列表**：某一行即将进入屏幕（UICollectionView 的预取回调）或手指按下时，确保它的首屏已在本地。
  - **会话内**：离顶部还有 1–2 屏时预取上一页；进入会话时调用 `SetActiveChat`，停留期间每分钟刷新一次。
  - **本地占用**：文本很小（100 个会话 × 50 条大约 5–10MB）；预取只拉缩略图，原件按需下载。
- **`Outbox`**：乐观发送，按 client_random_id 对齐。
- **`CallManager`**：负责 CallKit 或 App 内来电界面、LiveKit 入会、音频路由。
- **`MediaCache`**：见 6.3。

### 6.3 本地存储与缓存上限
- **原则**：服务端是唯一真相源，客户端只做缓存，并且有总上限。
- **分级加载**：

  | 级别 | 内容 | 获取时机 |
  |---|---|---|
  | 1 | thumbhash | 存在数据库里，随消息同步 |
  | 2 | 缩略图（约 320px） | 自动 |
  | 3 | 预览图（约 1280px） | 打开查看时 |
  | 4 | 原件 | 只在查看原图、保存、分享、打开文件时下载 |

  视频和大文件用 HTTP Range 边下边播。
- **设置项**：
  - 缓存上限：1GB、**2GB（默认）**、5GB、10GB 或不限。
  - 保留时长：3 天、**7 天（默认）**、30 天或永久。
  - 自动下载：按网络、类型、大小、私聊或群聊分别设置。
  - 清理：可以清理单个会话的缓存，也可以一键清理全部；能看到本地占用明细。
- **实现**：缓存文件放在 `Library/Caches/media/`，以 sha256 加 variant 作为键，本地同样只存一份；GRDB 里建索引表；在启动时、后台任务中以及超过上限时，按 LRU 加保留期淘汰。
- **本地消息库**：每个会话默认只保留最近 2000 条或 30 天，更早的翻页时向服务端拉取；全文检索走服务端。
- **上传**：先算 sha256，命中就秒传。

### 6.4 UI 与 Liquid Glass
- **原则**：玻璃效果只用于导航和控件层，消息等内容保持不透明；优先使用系统组件；尊重"降低透明度"设置和透明度滑块。
- **整体结构**：TabView（消息、联系人、搜索 `Tab(role: .search)`、设置），用 `tabBarMinimizeBehavior(.onScrollDown)` 收起标签栏；`tabViewBottomAccessory` 显示"QQ 离线 / 正在同步"或"**通话中 · 00:42**"。
- **聊天页**：玻璃导航栏，右侧有语音和视频通话按钮；输入栏用 `safeAreaBar(edge: .bottom)` 加 `GlassEffectContainer`；浮动的"回到底部"按钮和日期胶囊；群通话进行中时，顶部显示"加入群通话"横幅。
- **通话界面**：全屏，背景是大头像加模糊效果；底部是一组玻璃控件（静音、音频路由、摄像头、翻转、挂断，用 `glassEffectID` 做形变动画）；视频时远端全屏、本地小窗，后台继续播放用画中画；群语音显示参与人数和名单。
- **媒体查看器**："出现在 N 个聊天"入口，点进去可以跳转到原消息；"查看原图"按钮；原件已清理时给出提示。
- **存储管理**：本地缓存和服务端占用（逻辑、独占、共享）、去重节省的空间、会话策略、"预估后清理"。
- **其他**：iPad 用 NavigationSplitView；App 图标用 Icon Composer 制作；iOS 27 的新 API 以 SDK 的实际情况为准。

### 6.5 QQ 特有元素
- 小黄脸和超级表情行内渲染（静态图取自 QQ 自带的 `sysface_res/static`，打包在 App 的 `Resources/QQFaces`；名字表 `QQFaceNames.swift` 由 `face_config.json` 生成）。本地没有的新表情，用服务端随消息带来的表情名（`faceElement.faceText`）显示；商城表情显示为贴纸。
- 机器人消息：markdown 正文照常显示，开头那个当元数据用的空链接去掉；下面的按钮（NT 元素 17）只存档，不显示。
- **会话列表**：
  - 置顶会话排在最前面（顺序和 QQ 一致，按 `pinned_at`）。
  - "接收不提醒"的会话显示静音图标，未读数用灰色。
  - QQ 收进群助手的群（`cmdUinMsgMask = 2`）归入"群助手"这一行（即归档群聊）。
  - 角标分开显示：@我（红色 @）、@全体成员（橙色"全"，可按群关闭）、回复我（绿色回复图标）。
  - 置顶、提醒方式和 QQ 每 5 分钟对齐一次；本地改过的以本地为准。
- **聊天页**：
  - 点群友头像看资料，长按头像 @ 他。
  - 长按消息：回复、复制、@、回应、撤回自己的消息。
  - 输入"@"或从"+"菜单打开选人（含 @全体成员）；"+"菜单里还有"我的表情"（QQ 收藏表情，发送时服务端按 md5 去重入库）和照片。
  - 滚到底部即标为已读，和 QQ 的已读同步。
- 回复引用、@提及、戳一戳、合并转发（多层嵌套）、卡片消息、群文件、表情回应、撤回后灰色显示。
- 通话记录显示为服务消息（例如"语音通话 · 3:21"、"未接视频通话"、"已在其他设备接听"），联系人页里有"最近通话"列表。

## 7. 里程碑（每一阶段都有验收标准）
- **P-1 环境准备**（iOS 开发前必须完成；服务端和验证工作可以先开始）：
  - 清理磁盘，至少腾出约 60GB。
  - 把 macOS 升级到 26.6 或更高，安装 Xcode 27。
  - 加入 Apple Developer Program。
  - 给 OrbStack 分配 6GB 以上内存。
- **P0 消息链路验证**（OrbStack）：
  - 内容：用 NapCat 小号抓取各类样本，存到 `fixtures/`。
  - 需要验证的问题：
    - `real_seq` 是否单调且唯一。
    - 内部 API 能否按 seq 区间拉取。
    - 媒体链接的有效期和刷新方式。
    - QQ 消息里的 md5 和下载后的实际内容是否一致。
    - 能否用 `file://` 发送。
    - 本人从其他设备发出的消息是否会上报。
    - 是否和电脑上的官方 QQ 互踢。
  - 产出：冻结领域模型和 proto v1。
- **P0-C 通话可行性验证**（与 P0 并行，在 OrbStack 里进行）：
  1. G1：复现 maibot 桥。
  2. G2：搭 `qq-gui-lab`，录制指令。
  3. G3、G4（收看画面）和 G5（语音）：用浏览器版 LiveKit 测试页做端到端验证。
  - 产出：通话 POC、指令表 v1、延迟数据、QQ 和 NapCat 的版本锁定组合、降级结论。
- **P1 服务端存档 MVP**：
  - 内容：domain、迁移、插件消息模块、NapcatAdapter、摄取、对账补齐、认证；媒体部分包括 blobs、media_refs、三道去重、会话占用统计；只读 API 包括 ListDialogs、GetHistory、媒体下载、ListMediaUsages。
  - 验收：
    - 连续运行 72 小时，`verified_ranges` 内没有缺失。
    - 同一张图出现在 3 个会话里，物理上只有 1 份，并且能列出 3 个出处。
    - 增量统计和全量重算一致。
- **P2 同步与发送**：
  - 内容：pts、Subscribe、GetDifference、全部消息类型的发送、秒传、撤回、已读回写、草稿、APNs、检索 v1。
  - 验收：断网重连后状态一致；发送重试不重复；秒传命中时不再上传。
- **P3 iOS MVP**：
  - 内容：整体界面框架、会话列表、聊天页、媒体分级加载、本地缓存上限、"出现在 N 个聊天"跳转、SyncEngine、通知扩展。
  - 验收：日常聊天可以替代官方 QQ；缓存始终不超过上限。
- **P4 Telegram 式完善**：搜索界面、共享媒体页、合并转发、表情回应、群文件/公告/精华、文件夹、iPad 布局、Face ID 锁、加密推送、Share 扩展、存储策略、GC、冷热分层、存储管理页。
- **P5 通话桥接**（按 P0-C 的结论执行）：
  - 顺序：接听来电（1:1 语音）→ 拒接、挂断、静音、主动拨打 → 群语音 → 收看对方画面 → 发送摄像头画面（阶段 B）。
  - 配套：CallKit + PushKit 或通知降级、通话界面、通话记录、在别处接听和忙线处理。
  - 验收：iPhone 上能接打 QQ 好友的语音通话，能加入群语音；语音额外延迟 < 250ms，连续 30 分钟稳定；所有通话结果都有记录。
- **P6 加固**：Milky 适配器（只管消息）、深度回溯工具、备份与监控、QQ 和 NapCat 的升级回归流程（包括通话指令表回放）。

## 8. 验证方案
- **服务端**：
  - vitest：基于样本测试规范化、去重、撤回。
  - Testcontainers（PGroonga）：集成测试。
  - fast-check 属性测试：
    - 同步收敛：随机事件加随机断线，客户端最终状态必须等于服务端。
    - 占用统计：增量结果必须等于全量重算。
  - GC 要保证"保留最久的策略优先"；协议用 `buf lint` 和 `buf breaking` 守护，用 `buf curl` 做冒烟。
- **端到端**：
  - 两个测试 QQ 号互发全部消息类型，核对数据库和 sha256。
  - 同一个媒体转发到多个会话，核对 blob 数量、出处列表和跳转。
  - 混沌测试：重启服务端和 NapCat、断网，确认没有缺口、也没有重复发送。
- **iOS**：
  - XCTest：SyncEngine、GRDB 迁移、MediaCache 淘汰（超过上限后清理到上限以内）。
  - XCUITest：主流程。
  - 真机：推送、NSE、CallKit。
  - Instruments：1 万条消息滚动是否流畅。
- **通话**：
  - 插件单元测试：用录制的指令序列（`fixtures/avsdk/`）回放，校验接听参数映射和状态机。参考 maibot 的 `buildAcceptParams` 测试。
  - 脚本化呼叫：用测试号（手机或另一个 NapCat）覆盖来电、接听、拒接、拨打、双方挂断、在别处接听、未接、忙线、群语音。
  - 用"注入测试音 → 回环检测"测量额外延迟。
  - 连续运行 30 分钟，观察 CPU 和内存；AV Host 崩溃后应能自动恢复。

## 9. 风险与对策
- **依赖 AVSDK 和内核的非公开接口**：来电数组的布局、指令编号会随 QQ 版本变化。对策：锁定 QQ 和 NapCat 的版本；指令表做成配置；每次升级先回放录制的指令序列，再做一次真实来电测试；失效时自动降级为"来电提醒 + 通话记录"。
- **改了 QQ 的入口文件**（`loadNapCat.js` 分流）：在构建镜像时写入，带标记和备份，可以还原。QQ 升级后需要重新应用（参考 maibot 的安装器逻辑）。
- **arm64 未经验证**：maibot 没有说明在 arm64 上测过。G1 如果在 OrbStack 上不通过，就先去 x86_64 机器上验证。
- **只有一台 MacBook**：
  - 它不是常开主机：休眠期间消息事后能补齐，但通话会漏接。
  - 资源偏紧：磁盘和内存都不宽裕。
  - 对策：等有了常开主机（推荐 x86_64 Linux），整套 compose 迁过去。
- **视频**：发送摄像头画面依赖宿主机的 v4l2loopback 内核模块，放到阶段 B；收看对方画面靠截取窗口，画质有损。
- **CallKit 在中国大陆受限**：先在真机上验证；不可用就用时效性通知加铃声，通过 App 内来电界面接听。
- **账号风控**：开发期一律用小号；网络地区保持固定；补历史时限速。
- **登录位冲突**：NapCat 以电脑端身份登录，可能和电脑上的官方 QQ 互踢，P0 验证。
- **许可证**：maibot 的桥是 GPL-3.0，NapCat 禁止公开修改版。两者自用都没问题，**不要公开发布衍生代码**。
- **存储膨胀**：三道去重、会话策略、"保留最久者优先"的 GC、冷热分层、存储统计页。
- **iOS 开发环境**：需要 macOS 26.6+ 和 Xcode 27，并清理磁盘；推送、VoIP 和 Communication Notifications 需要 Apple Developer Program。
- **隐私**：服务端不暴露到公网；控制接口只监听回环地址并要求 token；磁盘和备份加密。

## 10. 默认假设（可随时调整）
- 先只接入 1 个 QQ 号，表结构从一开始就支持多个。
- 现阶段所有服务都跑在这台 MacBook 的 OrbStack 里；以后生产环境推荐家用 x86_64 Linux 主机。
- 服务端默认策略：≤ 200MB 自动下载，原件永久保留，冷存储默认关闭。
- 客户端默认值：缓存上限 2GB，媒体保留 7 天。

## 参考来源
- maibot-qq-voice-call（QQ AV Bridge）：https://github.com/ClaudiaGardner/maibot-qq-voice-call ，`bridge/README.md`、`bridge/PROTOCOL.md`、`bridge/napcat-plugin/index.mjs`、`bridge/av-host/host.cjs`
- NapCatQQ：https://github.com/NapNeko/NapCatQQ （#1678、#2066、#2067）
- NapCat-Docker：https://github.com/NapNeko/NapCat-Docker ；NapCat.Docker.Framework：https://github.com/NapNeko/NapCat.Docker.Framework
- SnowLuma：https://github.com/SnowLuma/SnowLuma
- Linux QQ 实时音视频技术实践：https://cloud.tencent.com/developer/article/2433985 ，https://cloud.tencent.com/developer/article/2429177
- QQ Linux 3.2.10 支持音视频通话：https://www.ithome.com/0/780/134.htm
- Milky：https://milky.ntqqrev.org/
- LiveKit：https://github.com/livekit/livekit ，https://github.com/livekit/node-sdks ，https://github.com/livekit/client-sdk-swift
- CallKit 在中国区的限制：https://developer.apple.com/forums/thread/121088
- Telegram 更新机制：https://core.telegram.org/api/updates
- Xcode 27 系统要求：https://blakecrosley.com/blog/xcode-27-release
