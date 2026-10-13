# packages/call-gateway · 通话音频网关

以「QQ 端」身份加入 LiveKit 房间：QQ 那边的声音（PulseAudio `qq_speaker.monitor`）送进房间，房间里 iPhone 的声音写进 `qq_mic`。在 `qqbridge-call-gateway` 容器里常驻（共享 QQ 容器的网络和 Pulse socket）。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 文件 | 内容 |
|---|---|
| `src/serve.ts` | 常驻模式：控制口 127.0.0.1:6120（`POST /bridges {room, token}` 入会、`DELETE /bridges/:room` 离开、`GET /status`），同一时间只桥一个房间 |
| `src/bridge.ts` | 一个房间的桥：发布 / 订阅音轨，两个方向按挂钟限速、超额丢帧（防止积压变成永久延迟） |
| `src/audio-io.ts` / `src/pcm.ts` | parec / pacat 读写；PCM 48kHz 单声道 s16le，每帧 10ms |
| `src/selftest.ts` / `src/phone-rtt.ts` | 不登录 QQ 的通路自检、全链路往返时延测量（`tools/call-e2e.sh`） |
| `src/cli.ts` / `src/token.ts` | 命令行入口、LiveKit 令牌 |

## 约定

- 服务端 `calls/gateway.ts` 是它的客户端（`CALL_GATEWAY_URL`、`CALL_GATEWAY_TOKEN`）。
- `GET /status` 的 `framesSent` 增长 = QQ 那边的声音进了房间；`framesReceived` = 收到 iPhone 的声音。本机 curl 记得 `--noproxy '*'`。
- `npx tsc --noEmit -p . && npx vitest run`；改完重建 `deploy/call-gateway/Dockerfile` 的镜像。
