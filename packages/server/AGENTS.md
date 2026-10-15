# packages/server · 服务端

Node 24 + TypeScript（strict，直接用 `--import tsx` 跑，不编译），Fastify + ConnectRPC，Postgres（PGroonga），Drizzle 只做迁移、查询写原生 SQL（`sql\`\``）。设计见 [docs/design.md](../../docs/design.md) 第 4 节。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 目录 / 文件 | 内容 |
|---|---|
| `app.ts` | 装配：建依赖（`createDeps`）、启动 HTTP、上游、下载器、推送、通话、定时任务 |
| `cli.ts` / `config.ts` | 命令行（迁移、清理、分层等）；环境变量（zod 校验，来自 `deploy/.env`） |
| `api/` | ConnectRPC 服务实现（`services.ts`，每个 service 一个函数）、proto ⇄ 领域转换（`convert.ts`）、依赖类型（`context.ts`）、媒体下载 / 上传 / 表情资源路由 |
| `upstream/` | NapCat 插件的 WebSocket 接入（`hub.ts`：事件先写收件箱再确认）、收件箱处理（`inbox.ts`）、OB11 → 领域映射（`napcat/map.ts`）、重连对账、补历史、QQ 设置同步 |
| `ingest/` | 入库：消息、服务事件、回应、媒体状态，分配 pts / chat_pts，发布到总线；也负责发临时事件（`publishCall`、`mediaReady`） |
| `sync/` | 单写者（`writer.ts`）、总线、差量（`difference.ts`）、Subscribe（`subscribe.ts`）、在线设备（`online-devices.ts`）、行转换（`rows.ts`） |
| `media/` | 存储（sha256 去重）、下载器（`fetcher.ts`）、缩略图 / 派生、冷热分层、清理、上传（tus）、表情 |
| `messages/` | 转发、合并转发、互动（回应、转文字、AI 语音、回应列表、共享媒体） |
| `outbox/` | 发件箱：按会话顺序经插件发往 QQ，重试 |
| `contacts/` | 好友 / 群 / 成员资料、头像；群公告、精华、群文件、相册（`group-content.ts`） |
| `calls/` | 通话状态机、LiveKit 令牌、网关客户端（见 [docs/calls.md](../../docs/calls.md)） |
| `push/` | APNs（`apns.ts`，HTTP/2 + JWT）、通知决策（`notifier.ts`：消息、来电、VoIP） |
| `dialogs/` `search/` `auth/` `admin/` | 会话设置、全文搜索、登录与设备令牌、系统状态与 QQ 扫码中转 |
| `db/` | 连接、schema、`migrations/`（`NNNN_名字.sql` + `meta/_journal.json` 里加一条） |
| `test/` | vitest（用真实 Postgres，见 `test/helpers`）；`fixtures` 在仓库根目录 |

## 关键约定

- **所有写操作走单写者**：`writers.forAccount(accountId).run(async (w) => …)`。需要在提交后做的事（发临时事件、推送）在 `run` 返回后做。
- **同步序号**：持久变化用 pts / chat_pts（客户端补差量能拿到）；只对在线设备有意义的（正在输入、通话、`mediaReady`）用 `publishEphemeral`，不占序号。
- **上游调用**：`hub.call(qqAccountId, 'x.xxx' | 'ob11', params, timeoutMs)`。插件那边的处理函数在 `napcat-plugin-qqbridge/src/upstream/handlers.ts`；新动作两边一起加。
- **改 proto**：先改 `packages/protocol/proto`，再生成（见 protocol 的 AGENTS.md），然后在 `api/services.ts` 实现、`convert.ts` 转换。
- **迁移**：只加不改；新列给默认值或可空。启动时自动跑。
- **QQ 灰色提示**（elementType 8）：`upstream/napcat/gray-tip.ts` 按子类型白名单译成「文字 + 人」，整条都认得时存为 `kind = 'service'`（不算未读、不推送）；只有 uid 的人在入库时（`resolveTipPeople`）按本地资料换成号码和名字。新子类型先抓样本再加（L2），加完跑 `pnpm cli messages:remap-gray-tips` 重写已存的。
- **QQ 返回的 id 不一定稳定**（群文件 file_id 每次列出都变）：要记的东西用稳定的键（见 [lessons.md](../../docs/lessons.md) L2）。

## 运行与测试

```bash
npx tsc --noEmit -p . && npx vitest run              # 改完必跑
launchctl kickstart -k gui/$(id -u)/com.xiaomouz.qqbridge.server
tail -f ~/Library/Logs/qqbridge/server.log           # pino JSON
pnpm cli migrate                                      # 手动迁移（一般启动时自动）
pnpm cli messages:remap-gray-tips                     # 灰色提示映射改了之后，按 raw 重写已存的（可重跑）
```

调试插件动作：`tools/qq.sh`，或容器里插件控制口的 `/v1/debug/raw?kind=ob11|methods|history`、`POST /v1/debug/rpc {"name":"x.xxx","params":{}}`。
