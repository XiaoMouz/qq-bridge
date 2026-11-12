# deploy · 部署

全部在一台 Mac mini（M2）上：OrbStack 跑容器，服务端是 launchd 常驻进程。总规矩见根目录 [AGENTS.md](../AGENTS.md)，部署步骤见 [README.md](../README.md)。

## 结构

| 路径 | 内容 |
|---|---|
| `docker-compose.yml` | `postgres`（pgroonga）、`qq`（NapCat + 插件 + AV Host + PulseAudio）、`livekit`、`call-gateway`（profile `calls`） |
| `qq/` | QQ 镜像：`Dockerfile`（基于 napcat-docker）、`supervisord.conf`（xvfb、pulseaudio、pulse-anchor、avhost、napcat）、`loadNapCat.js`（AV Host 分流）、Pulse 配置、各进程启动脚本 |
| `call-gateway/Dockerfile` | 通话网关镜像 |
| `livekit/livekit.yaml` | LiveKit 配置（信令 7880 只在回环，客户端经 `tailscale serve --https=7443` 访问；媒体 7881/7882 对外） |
| `launchd/install.sh` | 安装服务端的 launchd agent `com.xiaomouz.qqbridge.server`（日志 `~/Library/Logs/qqbridge/server.log`） |
| `.env` | **秘密**（数据库、令牌、LiveKit、APNs 等），不打印、不提交 |
| `data/` | 运行数据（不提交）：`postgres`、`media`（按 sha256 存的媒体）、`qface`（表情资源）、`napcat-config`（NapCat 配置、插件数据和 capture、开关文件 `qqbridge.env`）、APNs `.p8`（**不读不打印**） |

2026-10-24 起，代码在内置盘 `~/Workspace/qq-bridge`；数据库、NapCat 配置、QQ 登录态（`qq`、`qq-user`）、`.env` 和 APNs 密钥在 `~/deploy`（compose 经 `.env` 的 `QQBRIDGE_DATA` 挂载）；媒体、QQ 表情、诊断材料在 HDD-1 的 `XiaoMouz's Files/Depoly/QQ-Bridge`（`MEDIA_ROOT`）。仓库里 `deploy/data/` 是指向这些位置的符号链接。`data/qq` 保存 QQ 外层配置及 AV Host profile，`data/qq-user` 显式挂载到 `/app/.config/QQ`，都要备份；绑定挂载禁止自动创建缺失目录，启动前须确认 HDD-1 已挂载。迁移说明见 [迁出 Ext1](../docs/migration-internal.md)。

## 常用操作

```bash
docker ps                                                         # qqbridge-postgres / -qq / -livekit / -call-gateway
docker exec qqbridge-qq supervisorctl -c /etc/qqbridge/supervisord.conf status
docker exec qqbridge-qq supervisorctl -c /etc/qqbridge/supervisord.conf restart napcat   # 先问用户：可能要重新扫码
launchctl kickstart -k gui/$(id -u)/com.xiaomouz.qqbridge.server
tailscale serve status                                            # 7443 → 127.0.0.1:7880（LiveKit）要在
```

## 注意

- **数据库健康检查**：保留 `postgres.init: true` 和直接执行的 `CMD` 探针；`pg_isready -t` 必须短于 Docker 的超时。2026-10-23 隔离实测：shell 探针被超时杀掉后，遗留的 `pg_isready` 退出码 2 会被作为 PID 1 的 PostgreSQL 当成自身子进程崩溃，引发整库重置并留下索引锁。详见 [故障记录](../docs/incidents/2026-10-23-postgres-healthcheck.md)。
- **重启 NapCat**：登录态可能失效，要用户扫码（二维码在容器 `/app/napcat/cache/qrcode.png`，App 里「QQ 已掉线」也能扫）。插件热重载用 `tools/qq-plugin.sh deploy`，不用重启 NapCat。
- **QQ 本地数据（`data/qq-user`）**：插件每 6 小时删 7 天前的媒体缓存、QQ 日志和 NapCat 临时文件（见插件的 `qq-cleanup.ts`，`tools/qq.sh cleanup` 看会删多少）。
  **不要删 `nt_qq_*/nt_db`**（消息库，QQ 运行中一直打开；补历史、合并转发、回应、视频换链接都要从里面按 msgId 取原消息），也不要删 `nt_qq/global/nt_db`（登录态）。
  2026-11-12 实测：服务端不读 QQ 本地媒体文件；群视频 7 天后在 QQ 服务器上就拿不到了，清本地缓存不影响。
- **拷进容器的文件**（插件、`host.cjs`）重启容器后还在，重建容器时以镜像为准——长期改动要重建镜像。
- **拉镜像**：OrbStack 的 Docker 引擎要经 `~/.orbstack/config/docker.json` 里的代理（host.internal:6152）；QQ / 腾讯的域名在代理里要直连（避免异地登录风控）。
- **公网入口（Cloudflare Tunnel）**：`qq.mou.best` → `127.0.0.1:8080`，挂在本机已有的 `comfyui` 隧道上（`~/.cloudflared/config.yml`，launchd `com.cloudflare.cloudflared`）。改配置后 `cloudflared tunnel ingress validate` 再 `launchctl kickstart -k gui/$(id -u)/com.cloudflare.cloudflared`（comfyui.mou.best 会断几秒）。凭据文件 `~/.cloudflared/*.json` 不打印。通话的 LiveKit 没走隧道。
- **LiveKit 的 Tailscale 转发**（`tailscale serve --bg --https=7443 http://127.0.0.1:7880`）曾经丢过，接听报连不上时先看这个。
