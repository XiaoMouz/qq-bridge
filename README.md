# QQ Bridge

个人自用的 QQ 存档与客户端系统：
- **服务端**：基于 NapCat，按 Telegram 思路设计，负责存档消息和媒体（媒体按哈希去重），并为多设备提供增量同步。
- **客户端**：自研原生 iOS App（iOS 27）。
- **通话**：在 App 内桥接 QQNT 的语音和视频通话。

完整设计见 [docs/design.md](docs/design.md)。**本项目不公开、不商用**：NapCat 的许可证禁止公开发布修改版，通话桥接部分又参考了 GPL-3.0 代码。

## 当前进度

| 部分 | 状态 |
|---|---|
| P0 / P0-C 验证套件（NapCat 插件、AV Host、QQ 容器） | 已完成，等扫码登录后验证 |
| 服务端核心（`packages/server`、`domain`、`protocol`） | 已完成第一版（含两组属性测试） |
| 媒体下载任务（下载、去重、缩略图、重试、按上游换新链接） | 已完成 |
| 上游链路（插件持久队列 → 服务端收件箱 → 入库；对账预热） | 已完成，用真实插件代码联调测试；**扫码后即开始存档**，映射细节等真实样本再校对 |
| 发送（秒传与断点续传上传、发件箱幂等、按会话顺序发送）、撤回、已读回写 | 已完成；真正发到 QQ 要等扫码后验证 |
| 全文搜索、置顶 / 免打扰 / 草稿 | 已完成 |
| 存储策略与原件清理（手动清理、按保留期定时清理、恢复） | 已完成 |
| 通话网关的音频通路（`packages/call-gateway`） | 已完成，不登录 QQ 也能端到端实测：全链路往返约 190–200ms，单向额外延迟约 100ms |
| 媒体处理：按内容识别类型、语音转 AAC + 波形、视频封面 + faststart 流式播放版本、上传后生成缩略图 | 已完成，已在真实数据上补处理 |
| 通知适配：服务事件（入群、禁言、戳一戳、设精华……）、表情回应、"正在输入" | 已完成，已在真实数据上补处理 |
| 存档完整性：按 seq 检测缺口并后台补齐、往上翻页时懒回填、单条失败不拖累整个会话 | 已完成，已在真实数据上补齐 |
| 深度归档（从第一条补起）、存档完整性列表 | 已完成 |
| 表情回应、"正在输入"、合并转发展开（含嵌套和其中的媒体）、共享媒体列表、推送令牌登记 | 已完成 |
| 联系人与资料：好友 / 群列表各一次请求建索引（每天刷新）；头像在打开会话时按需加载；详细资料和群成员在打开资料页时请求，不在后台爬取 | 已完成 |
| 冷热分层存储（按访问、大小、时间、会话和全局配额下沉；常用的提回热存储）、按会话的占用明细与策略 | 已完成；冷存储在外接硬盘 HDD-1 上，盘不在时从 QQ 取回、拿不到返回过期 |
| 管理接口：系统状态、扫码登录中转、通话桥健康状况 | 已完成 |
| 通话桥 G1：无界面接听 QQ 来电、双向语音 | **已通过**（2026-10-04，主号，arm64）；20050 重登死循环已查明并修复 |
| 服务端通话管理（CallService）、常驻通话网关、网页版接听测试页 | 已完成，等端到端实测（G5） |
| APNs | 待做 |

**真机验证（2026-10-02，主号）**：
- 扫码登录后插件连上服务端，对账预热了 49 个会话。
- 实时消息服务端内部延迟约 18ms。
- 发送文字和图片（含上传、按 md5 去重）、撤回都已打通。

全仓库共 168 个测试：服务端 98 个、iOS 核心 13 个、NapCat 插件 37 个、领域模型 15 个、通话网关 5 个（其中通话网关的实时音频集成测试最近一次未达阈值，见下文）。
| iOS 客户端核心 QQBridgeKit（协议、网络、同步引擎、本地库、媒体缓存、发送），见 [ios/README.md](ios/README.md) | 已完成，13 个测试；`swift run qqbridge-check` 可连真实服务端验收 |
| iOS App 界面 | 等 Xcode 27（系统已是 macOS 27，满足要求；还需腾出约 25GB 磁盘） |

### 服务端核心

| 目录 | 内容 |
|---|---|
| [packages/domain](packages/domain) | 领域模型（Milky 语义）和纯函数：消息段的标志位和纯文本、"保留最久者优先"的原件保留规则、按会话的占用统计定义、Telegram 的更新应用规则。 |
| [packages/protocol](packages/protocol) | 客户端协议，用 Protobuf 定义，buf lint 用 STANDARD 规则。TS 代码由 buf 生成，Swift 代码以后从同一份 proto 生成。 |
| [packages/server](packages/server) | <ul><li>PostgreSQL + PGroonga；用 Drizzle 生成迁移，复杂查询写原生 SQL。</li><li>单写者：用行锁分配 pts 和 chat_pts，提交后才发布更新。</li><li>版本化行增量同步：GetDifference、GetChatDifference，以及"先差量后实时"的 Subscribe 流。</li><li>媒体：内容寻址存储，三道去重（QQ md5 下载前去重、sha256、秒传判定），出处查询，按会话的逻辑、独占、共享占用统计，清理预估。</li><li>媒体下载任务：收到消息就下载（QQ 链接会过期）；按策略限制大小；图片生成缩略图（320px）、预览图（1280px）和 thumbhash；链接失效时向上游换新链接；失败按指数退避重试。详见 docs/design.md 4.6。</li><li>切换会话不等待：批量首屏接口 GetChatDifferences 供客户端预取；SetActiveChat 让正在看的会话的媒体优先下载（docs/design.md 4.7）。</li><li>发送：秒传 + tus 断点续传上传；发件箱按 client_random_id 幂等、进度经 pts 同步到所有设备；同一会话按顺序发送，QQ 离线时等待，插件按 id 去重防止重复发送；撤回与已读回写 QQ。</li><li>全文搜索（PGroonga）；置顶、免打扰、草稿多端同步。</li><li>存储策略（三层、按字段继承）与原件清理：手动清理、按保留期每天自动清理，只删所有引用方都不再需要的原件，缩略图保留，重新下载回来自动恢复。</li><li>认证：argon2id 密码 + 设备令牌。</li><li>ConnectRPC API，以及带签名、支持 Range 的媒体下载。</li></ul> |

属性测试覆盖两件事：
- **同步收敛**：随机写入，加上会丢更新、会断线的模拟客户端；追平后状态必须与服务端逐字段一致。
- **占用统计**：增量统计必须等于全量重算。

这两组测试都做过变异检查，确认能抓到注入的 bug。开发过程中，它们还真的发现了一个会话快照不一致的 bug，已修复，详见 docs/design.md 4.5。

### 上游链路：扫码后自动开始存档

QQ 容器里的插件会主动连服务端（`ws://host.internal:8080/upstream/napcat`，口令是 `deploy/.env` 里的 `UPSTREAM_TOKEN`）：
- 服务端没开时，事件先存在插件的本地队列里，服务端启动后自动续传，不丢消息。
- 连上之后会对最近会话做一次对账：服务端没见过的会话预热最新 200 条，断线期间漏掉的消息自动补齐（限速每秒 1 次）。
- 服务端日志里可以看到：`upstream connected`（插件已连上）、`upstream reconcile finished`（对账结果）、`upstream realtime latency (ms)`（每分钟一次的实时延迟统计）。

维护命令（在仓库根目录执行）：
- `pnpm --filter @qqbridge/server cli media:reprocess`：补处理已存档的媒体（纠正类型、补缩略图、语音可播放版本、视频封面和 faststart 版本）。
- `pnpm --filter @qqbridge/server cli inbox:reprocess ignored`：新支持某类上游事件后，重新处理以前忽略的事件。
- `sh tools/qq-plugin.sh deploy`：构建插件并热更新到运行中的 QQ 容器（经 NapCat WebUI 重载插件），**不用重建容器、不用重新扫码**。
- `sh tools/qq-plugin.sh calls on|off`：开关通话桥。开关写在 `deploy/data/napcat-config/qqbridge.env`，覆盖 compose 里的环境变量；AV Host 会跟着自动启动或退回空转。
- 通话（G5）：`docker compose -f deploy/docker-compose.yml --env-file deploy/.env --profile calls up -d livekit call-gateway` 启动 LiveKit 和常驻网关；`deploy/.env` 里配好 `LIVEKIT_PUBLIC_URL`、`CALL_GATEWAY_TOKEN`、`CALL_LAB=1` 后，手机经 Tailscale HTTPS 打开 `/lab/call` 即可接听 QQ 来电。需要先在 Tailscale 后台打开 HTTPS 证书，再运行 `tailscale serve --bg --https=443 http://127.0.0.1:8080` 和 `tailscale serve --bg --https=7443 http://127.0.0.1:7880`。

本机运行服务端：

```bash
docker compose -f deploy/docker-compose.yml --env-file deploy/.env up -d postgres
```

```bash
OWNER_PASSWORD='换成你的密码' pnpm --filter @qqbridge/server cli create-owner owner
```

```bash
pnpm --filter @qqbridge/server cli serve
```

常驻运行（launchd，登录后自动启动，崩溃自动拉起，日志在 `~/Library/Logs/qqbridge/server.log`）：

```bash
sh deploy/launchd/install.sh
```

改了服务端代码后重启：`launchctl kickstart -k gui/$(id -u)/com.xiaomouz.qqbridge.server`；移除：`sh deploy/launchd/install.sh uninstall`。装了常驻服务就不要再手动 `serve`，否则会抢 8080 端口。

`deploy/.env` 里需要填好 `POSTGRES_PASSWORD`、`DATABASE_URL`、`MEDIA_URL_SECRET`，参考 `deploy/.env.example`。下载任务随 `serve` 一起启动，并发数和默认大小上限由 `MEDIA_FETCH_CONCURRENCY`、`MEDIA_AUTO_FETCH_MAX_BYTES` 控制。发送时 NapCat 从 `UPSTREAM_MEDIA_BASE_URL`（默认 `http://host.internal:<PORT>`）下载要发的媒体；单个上传的大小上限是 `UPLOAD_MAX_BYTES`（默认 1GB）。改了 proto 之后要重新生成代码：

```bash
pnpm --filter @qqbridge/protocol generate
```

运行全部测试（需要 OrbStack，测试会自动启动 PGroonga 容器）：

```bash
pnpm -r test
```

### 通话网关（音频通路）

[packages/call-gateway](packages/call-gateway) 以"QQ 端"的身份加入 LiveKit 房间，在两个方向之间转发声音：
- **QQ → iPhone**：读 QQ 容器里的 `qq_speaker.monitor`（对方的声音），发到 LiveKit。
- **iPhone → QQ**：从 LiveKit 收 iPhone 的声音，写入 `qq_mic`（QQ 的麦克风）。

| 测量（都不需要登录 QQ） | 结果 |
|---|---|
| 只经过 LiveKit（`pnpm --filter @qqbridge/call-gateway test`，会自动启动一个 LiveKit 测试容器） | 单向 69–214ms |
| 只经过 PulseAudio（`pulse-selftest`） | 下行 19–32ms，上行 40–43ms |
| 全链路（`tools/call-e2e.sh`：假 iPhone ⇄ LiveKit ⇄ 网关容器 ⇄ PulseAudio 回环） | 往返 190–222ms，即单向约 100ms，零丢帧 |

调试过程中解决了两个延迟问题：
- **积压变成永久延迟**：管道和 pacat 里的积压，在两端都按实时速度进出时会一直留着。现在两个方向都按挂钟限速、超额就丢帧。
- **虚拟声卡时快时慢**：PulseAudio 的 null-sink 没人要求低延迟时按 2 秒为一块渲染，会让链路时快时慢地多出 1 秒以上。现在 QQ 容器里常驻两个 10ms 的录音流（`pulse-anchor`），把声卡钉在 10ms。

常用命令：

```bash
docker compose -f deploy/docker-compose.yml --env-file deploy/.env --profile calls run --rm --no-deps call-gateway pulse-selftest
```

```bash
tools/call-e2e.sh
```

在 OrbStack 上，Docker 引擎跑在虚拟机里，LiveKit 的端口只能绑 `0.0.0.0` 或 `127.0.0.1`，不能只绑 Tailscale IP。节点 IP（`LIVEKIT_NODE_IP`）用这台 Mac 的 Tailscale IP，iPhone 和网关容器都能经它连上。

## P0 / P0-C 验证套件

| 目录 | 内容 |
|---|---|
| [packages/napcat-plugin-qqbridge](packages/napcat-plugin-qqbridge) | NapCat 插件，三部分：<br>· **消息上游**：事件进本地持久队列，经 WebSocket 推给服务端，按游标确认、断线续传；响应服务端的换链接、拉历史等调用。<br>· **P0 采样器**：把所有事件连同原始 NT 消息写成 JSONL，探测媒体链接的有效期，提供按 seq 拉历史等研究接口。<br>· **通话信令桥**：在 QQ 内核的 AVSDK 服务和 AV Host 之间转发数据，并维护通话状态机。 |
| [packages/av-host](packages/av-host) | 由 QQ 自带的 Electron 起的第二个进程，用来加载 `libAVSDKPlugin.so`。 |
| [deploy/qq](deploy/qq) | QQ 容器：在官方 `mlikiowa/napcat-docker:v4.18.28` 基础上加了三样东西：<br>· 隔离的 PulseAudio（`qq_speaker` 和 `qq_mic` 两个虚拟设备）；<br>· supervisord；<br>· 可还原的入口分流（`loadNapCat.js`）。 |
| [tools/qq.sh](tools/qq.sh) | 调试工具：查状态、接听来电、录下对方的声音、往 QQ 麦克风放测试音。 |
| [tools/analyze-capture.mjs](tools/analyze-capture.mjs) | 采样分析：seq 语义、本人消息、md5 等去重字段、链接有效期、通话事件。 |

## 本机运行（OrbStack）

### 1. 构建插件和镜像

```bash
pnpm install
```

```bash
pnpm -r build
```

```bash
cp deploy/.env.example deploy/.env
```

然后编辑 `deploy/.env`：把 `NAPCAT_UID` 和 `NAPCAT_GID` 填成 `id -u` 和 `id -g` 的结果，`QQ_ACCOUNT` 填**小号**，再设置 `NAPCAT_WEBUI_TOKEN`。

```bash
docker compose -f deploy/docker-compose.yml up -d --build
```

### 2. 扫码登录

打开 http://127.0.0.1:6099/webui ，用 `NAPCAT_WEBUI_TOKEN` 登录，然后用小号所在的手机 QQ 扫码。

### 3. 确认各部分已就绪

```bash
tools/qq.sh status
```

预期结果：`serviceAvailable: true`、`listenerRegistered: true`、`loginPosted: true`。

```bash
tools/qq.sh avhost
```

预期结果：`pluginFound: true`，并且 `methods` 里包含 `postMessage`。

```bash
tools/qq.sh pulse
```

预期结果：默认 sink 是 `qq_speaker`，默认 source 是 `qq_mic_source`。

## P0：消息链路验证

用另一个账号（或手机）给小号发各种类型的消息（文本、表情、图片、GIF、语音、视频、文件、合并转发、回复、@、戳一戳、撤回、表情回应），也用小号自己在手机上发几条。然后执行：

```bash
node tools/analyze-capture.mjs
```

```bash
tools/qq.sh get '/x/recent_contacts?count=20'
```

```bash
tools/qq.sh get '/x/history_by_seq?scene=group&peer=<群号>&seq=<某个seq>&count=20'
```

链接有效期的探测在收到消息后的 1 分钟、15 分钟、1 小时、6 小时、24 小时各做一次，所以要等一天才能看到完整结果。

## P0-C / G1：通话桥接验证

1. 在 `deploy/.env` 里设置 `QQBRIDGE_CALL_AUTO_ACCEPT=1`，然后重新执行 `docker compose ... up -d`。
2. 用另一个账号给小号打 QQ 语音电话。

   ```bash
   tools/qq.sh call
   ```

   这时 phase 应该依次经过 `ringing → accepting → accepted → connected`。
3. 通话中录下对方的声音：

   ```bash
   tools/qq.sh record 15
   ```

   录音保存在 `fixtures/raw/`。
4. 往 QQ 麦克风放测试音，对方应该能听到 440Hz 的声音：

   ```bash
   tools/qq.sh tone 10
   ```

5. 验证完把 `QQBRIDGE_CALL_AUTO_ACCEPT` 改回 0。以后由 iPhone 端接听：

   ```bash
   tools/qq.sh accept
   ```

> 采样数据（`deploy/data/`、`fixtures/raw/`）里有聊天内容和登录态，已被 `.gitignore` 排除，不要外传。

## 常见问题

- **OrbStack 拉不到 Docker Hub 镜像（TLS handshake timeout）**：直连被墙了，OrbStack 的 `network_proxy` 设置对 Docker 引擎拉镜像不生效。解决办法是在 `~/.orbstack/config/docker.json` 里给引擎配代理，把 `host.internal` 指向本机代理端口，例如：

  ```json
  {
    "proxies": {
      "http-proxy": "http://host.internal:6152",
      "https-proxy": "http://host.internal:6152",
      "no-proxy": "localhost,127.0.0.1,::1,host.internal,.local"
    }
  }
  ```

  改完执行 `orb restart docker`。
- **构建镜像时 apt 报 Unmet dependencies**：官方镜像用 `dpkg --force-depends` 装 QQ 时漏了 `xdg-utils`。Dockerfile 已经先执行 `--fix-broken` 补齐，QQ 不会被卸载。
- **AV Host 日志里出现 `Failed to load Pepper module ... cannot open shared object file`**：通话引擎缺运行库。在容器里对 `/opt/QQ/resources/app/avsdk` 下的 `.so` 执行 `ldd`，查出缺什么，再补进 Dockerfile。
- **代理规则要让腾讯/QQ 的域名直连**：否则容器里的 QQ 流量可能经代理从异地出口，触发风控。
