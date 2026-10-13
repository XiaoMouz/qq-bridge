# packages/napcat-plugin-qqbridge · NapCat 插件

运行在 QQ 进程里（QQNT 自带的 Node），用 esbuild 打成单文件 `dist/index.mjs`，不能带原生模块。保持「薄」：只采集事件、执行动作、返回 NT 原始结构，业务判断都在服务端。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 文件 | 内容 |
|---|---|
| `src/index.ts` | 入口：`plugin_init` / `plugin_cleanup`，装配控制口、上游连接、通话桥 |
| `src/core.ts` | 访问 NapCat 内核（`session`、`msgApi`、`uidByUin`…），每个入口都做存在性检查（NapCat 内部 API 不是稳定契约） |
| `src/config.ts` | 环境变量 + 开关文件（`/app/napcat/config/qqbridge.env`，即 `deploy/data/napcat-config/qqbridge.env`） |
| `src/control-server.ts` | 容器内回环的 HTTP 控制口（Bearer 令牌） |
| `src/debug-routes.ts` | 研究用：`GET /v1/debug/raw?kind=ob11|methods|history|groups…`，`POST /v1/debug/rpc {"name":"x.xxx","params":{}}` 直接调处理函数 |
| `src/probe.ts` / `src/capture.ts` | P0 采样、事件抓取（写到插件数据目录的 `capture/*.jsonl`） |
| `src/upstream/link.ts` / `queue.ts` / `wire.ts` | 到服务端的 WebSocket：事件先进本地持久队列，按服务端确认的游标续传。`wire.ts` 和服务端的 `upstream/wire.ts` 必须同步改 |
| `src/upstream/forwarder.ts` | OneBot 事件 → 队列（补齐原始字段） |
| `src/upstream/handlers.ts` | 服务端能调的动作：`x.history`、`x.send`、`x.react`、`x.forward*`、`x.ptt_text`、`x.ai_voices`、`x.reaction_users`、`x.call.*`、`ob11`（透传 OneBot 动作）… |
| `src/upstream/sender.ts` | 发送（按 client_random_id 去重） |
| `src/call/avsdk-bridge.ts` | 通话信令桥：内核 AVSDK 监听 ⇄ AV Host；来电 / 接听 / 拒接 / 挂断 / 打出去 / 群语音。指令和事件含义见 [docs/calls.md](../../docs/calls.md) |
| `src/call/accept-params.ts` | 接听参数映射（改写自 maibot，GPL-3.0，自用不分发） |
| `test/` | vitest（不需要 QQ） |

## 关键约定

- **加一个服务端能调的动作**：在 `handlers.ts` 加 `'x.名字': async (params) => …`，返回原始数据；服务端在对应 service 里 `hub.call(qq, 'x.名字', …)`。需要 OneBot 已有的动作就直接 `ob11` 透传，不用在插件里加。
- **热重载**：`tools/qq-plugin.sh deploy` 会重载插件但 **QQ 进程不重启**。挂在内核上的监听、全局定时器、队列都要按「重载很多次」设计：进程级的东西挂在 `globalThis[Symbol.for('qqbridge.…')]`，重载时交接给新实例（例子：`avsdk-bridge.ts` 的 `globalDispatch`）。内核的 `remove…Listener` 不一定生效。
- **不猜字段含义**：新事件先看 capture 目录里的原始数据（[lessons.md](../../docs/lessons.md) L2）。
- **NT 的会话类型**：私聊 1、群 2、临时会话 100；好友会话要 uid（`uidByUin`）。

## 构建、部署、调试

```bash
npx tsc --noEmit -p . && npx vitest run
sh ../../tools/qq-plugin.sh deploy                      # 构建 → 拷进容器 → 重载（约 1 秒）
sh ../../tools/qq-plugin.sh calls on|off                # 通话桥开关
docker logs --since 5m qqbridge-qq 2>&1 | grep qqbridge  # 插件日志
```

抓到的原始数据：`deploy/data/napcat-config/plugins/napcat-plugin-qqbridge/capture/`（含聊天内容，不要外传）。
