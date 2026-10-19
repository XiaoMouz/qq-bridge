# QQ Bridge（BetterChat）

个人自用的 QQ 存档与客户端系统：
- **服务端**：基于 NapCat，按 Telegram 思路设计，持续存档消息和媒体（媒体按 sha256 去重），给多设备提供增量同步（pts / chat_pts、Subscribe 推送）。
- **客户端「BetterChat」**：自研原生 iOS App（iOS 26+，TestFlight 分发）和 [macOS 版](macos/README.md)（Mac Catalyst 独立工程）。
- **通话**：在 App 里接打 QQ 语音电话（AV Host 加载 QQ 自己的通话引擎 + PulseAudio + LiveKit）。

全部跑在一台 Mac mini（M2）上：Postgres、QQ（NapCat）、LiveKit、通话网关在 OrbStack 里，服务端是 launchd 常驻进程。**本项目不公开、不商用**：NapCat 的许可证禁止公开发布修改版，通话桥接部分又参考了 GPL-3.0 代码。

## 文档

| 文档 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 项目总入口：目录说明、常用命令、规矩、代码准则（各子目录另有自己的 AGENTS.md） |
| [docs/design.md](docs/design.md) | 总体设计：架构、表结构、同步模型、媒体存储、推送、通话方案 |
| [docs/changelog.md](docs/changelog.md) | 修改记录（按时间和功能分组，带 commit 和发布版本） |
| [docs/lessons.md](docs/lessons.md) | 犯过三次的错误和对策 |
| [docs/calls.md](docs/calls.md) | 通话桥实测：引擎指令表、内核回调含义、调试方法 |
| [docs/migration-ext1.md](docs/migration-ext1.md) | 迁移到 Ext1：当前路径、运行数据、备份和回退说明 |
| [ios/README.md](ios/README.md) | iOS 核心库 QQBridgeKit 说明、命令行验收 |

## 当前状态（2026-10-16）

iOS App 1.16 (24) 已上 TestFlight 日常使用；macOS 版 1.1 (2)。

| 部分 | 状态 |
|---|---|
| 存档：实时消息、断线续传、对账补齐、按 seq 补缺口、往上翻页懒回填、深度归档 | 已上线 |
| 媒体：三道去重、缩略图 / 预览 / 语音转码 / 视频封面、按会话类型的下载规则、冷热分层（当前未启用冷存储）、按会话的占用与清理 | 已上线 |
| 同步：GetDifference / GetChatDifference、Subscribe 推送（含正在输入、`mediaReady`、来电等临时事件） | 已上线 |
| 发送：文字、图片、视频、文件、语音、相机拍摄、粘贴媒体、转发 / 合并转发；秒传与断点续传；发件箱幂等 | 已上线 |
| 消息类型：回复、@、小黄脸 / 超级表情、商城表情、卡片、合并转发、机器人 markdown 与按钮、表情回应、撤回（保留原内容） | 已上线 |
| QQ 灰色提示（撤回、进群、拍一拍、文件已接收、设精华……）显示成系统提示；还不支持的元素（红包、长消息……）显示成可查看原始数据的卡片 | 已上线（2026-10-15） |
| 群：公告、精华、群文件（下载、删除、移动、多选）、相册、成员与管理操作 | 已上线 |
| 搜索：会话 / 联系人即时筛选、聊天记录全文搜索（PGroonga，分页、跳到原消息） | 已上线 |
| 推送：APNs 通讯通知（发送者头像、快速回复）、按会话提醒设置、VoIP 来电（CallKit） | 已上线 |
| 语音：转文字（用 QQ 自己的识别，可自动转）、AI 语音（群） | 已上线 |
| 通话：1:1 语音接打、挂断检测、群语音加入 | 已上线，双向通话的真机体验仍在打磨 |
| 视频通话 | 未做 |

测试：服务端 162 个（vitest，用真实 Postgres）；QQBridgeKit、NapCat 插件、领域模型、通话网关、macOS 各有自己的测试，命令见各目录的 AGENTS.md。

## 访问方式

服务端只监听 `127.0.0.1:8080`，对外两条路：

| 入口 | 用途 |
|---|---|
| `https://qq.mou.best` | Cloudflare Tunnel（本机已有的 `comfyui` 隧道上加的一条规则，配置在 `~/.cloudflared/config.yml`）。App 登录页的服务器地址填 `qq.mou.best` 即可，自动走 https。实时同步每 25 秒有心跳，不会被 Cloudflare 的空闲超时断开；单次上传受 Cloudflare 请求大小上限限制 |
| Tailscale | 原来的内网入口；LiveKit（通话）目前仍经 Tailscale 的 `tailscale serve --https=7443`，没走隧道 |

本机调试（模拟器）直接用 `127.0.0.1:8080`。

## 服务端

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
- `pnpm --filter @qqbridge/server cli messages:remap-gray-tips`：QQ 灰色提示的映射改了以后，按原始消息重写已存的（可重跑）。
- `sh tools/qq-plugin.sh deploy`：构建插件并热更新到运行中的 QQ 容器（经 NapCat WebUI 重载插件），**不用重建容器、不用重新扫码**。
- `sh tools/qq-plugin.sh calls on|off`：开关通话桥。开关写在 `deploy/data/napcat-config/qqbridge.env`，覆盖 compose 里的环境变量；AV Host 会跟着自动启动或退回空转。
- 通话（G5）：`docker compose -f deploy/docker-compose.yml --env-file deploy/.env --profile calls up -d livekit call-gateway` 启动 LiveKit 和常驻网关；`deploy/.env` 里配好 `LIVEKIT_PUBLIC_URL`、`CALL_GATEWAY_TOKEN`、`CALL_LAB=1` 后，手机经 Tailscale HTTPS 打开 `/lab/call` 即可接听 QQ 来电。需要先在 Tailscale 后台打开 HTTPS 证书，再运行 `tailscale serve --bg --https=443 http://127.0.0.1:8080` 和 `tailscale serve --bg --https=7443 http://127.0.0.1:7880`。

本机运行服务端：

绑定挂载不再自动创建缺失目录。仅首次部署时创建数据库目录；迁移或恢复已有实例时应先恢复数据，不能用空目录替代。外接盘上的项目须先确认磁盘已挂载。

```bash
mkdir -p deploy/data/postgres
```

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

然后编辑 `deploy/.env`：把 `NAPCAT_UID` 和 `NAPCAT_GID` 填成 `id -u` 和 `id -g` 的结果，`QQ_ACCOUNT` 按根目录 `AGENTS.md` 的账号约定填写，再设置 `NAPCAT_WEBUI_TOKEN`。

仅全新部署时创建运行目录；恢复已有实例时先还原对应数据。`qq-user` 保存 QQ 登录态，不能只备份外层的 `qq` 目录。

```bash
mkdir -p deploy/data/napcat-config deploy/data/qq deploy/data/qq-user deploy/data/postgres
```

```bash
docker compose -f deploy/docker-compose.yml up -d --build
```

### 2. 扫码登录

打开 http://127.0.0.1:6099/webui ，用 `NAPCAT_WEBUI_TOKEN` 登录，然后用同一账号的手机 QQ 扫码。本机使用主号，不要使用 `qq-bot` 的机器人账号。

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
