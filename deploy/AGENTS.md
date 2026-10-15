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

## 常用操作

```bash
docker ps                                                         # qqbridge-postgres / -qq / -livekit / -call-gateway
docker exec qqbridge-qq supervisorctl -c /etc/qqbridge/supervisord.conf status
docker exec qqbridge-qq supervisorctl -c /etc/qqbridge/supervisord.conf restart napcat   # 先问用户：可能要重新扫码
launchctl kickstart -k gui/$(id -u)/com.xiaomouz.qqbridge.server
tailscale serve status                                            # 7443 → 127.0.0.1:7880（LiveKit）要在
```

## 注意

- **重启 NapCat**：登录态可能失效，要用户扫码（二维码在容器 `/app/napcat/cache/qrcode.png`，App 里「QQ 已掉线」也能扫）。插件热重载用 `tools/qq-plugin.sh deploy`，不用重启 NapCat。
- **拷进容器的文件**（插件、`host.cjs`）重启容器后还在，重建容器时以镜像为准——长期改动要重建镜像。
- **拉镜像**：OrbStack 的 Docker 引擎要经 `~/.orbstack/config/docker.json` 里的代理（host.internal:6152）；QQ / 腾讯的域名在代理里要直连（避免异地登录风控）。
- **公网入口（Cloudflare Tunnel）**：`qq.mou.best` → `127.0.0.1:8080`，挂在本机已有的 `comfyui` 隧道上（`~/.cloudflared/config.yml`，launchd `com.cloudflare.cloudflared`）。改配置后 `cloudflared tunnel ingress validate` 再 `launchctl kickstart -k gui/$(id -u)/com.cloudflare.cloudflared`（comfyui.mou.best 会断几秒）。凭据文件 `~/.cloudflared/*.json` 不打印。通话的 LiveKit 没走隧道。
- **LiveKit 的 Tailscale 转发**（`tailscale serve --bg --https=7443 http://127.0.0.1:7880`）曾经丢过，接听报连不上时先看这个。
