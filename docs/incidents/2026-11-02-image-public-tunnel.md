# 2026-11-02：图片排查时恢复公网隧道

时间为上海时间。

- 17:08 起检查图片无法下载：服务端健康检查通过，Postgres 和 QQ 容器在线；内置盘约剩 27 GiB，媒体盘约剩 619 GiB。最近三小时图片无 pending / fetching / failed；最近主动请求的图片已 stored。
- 抽查最近请求的原图、压紧缩略图：本机和 Tailscale 返回 200，完整内容 SHA-256 一致。未据此断定用户客户端正常。
- 公网隧道常驻进程持续报 `dial tcp 198.18.1.56:7844` / `198.18.1.92:7844: connect: connection refused`，未连接 Cloudflare；公共 DNS 返回的实际节点属于 198.41.192.x / 198.41.200.x。故障在隧道连接解析路径，不能归因于 QQ 图片下载。
- 临时连接器使用 `--dns-resolver-addrs 1.1.1.1:53` 后成功建立四条连接。验证后给 `~/Library/LaunchAgents/com.cloudflare.cloudflared.plist` 的运行参数增加 `1.1.1.1:53`、`1.0.0.1:53` 两个解析器，保留原代理和 HTTP/2 配置；重新加载常驻服务，确认四条 HTTP/2 连接注册成功。第一次 bootstrap 因旧服务尚未卸载完成失败，复查旧服务已移除后重试成功。
- 常驻连接恢复后结束临时连接器。经本机已配置的代理访问公网健康检查返回成功；使用客户端格式 User-Agent 抽查三张图片，均返回 200、SHA-256 一致，用时 0.58–0.94 秒。Python 默认 User-Agent 另被 Cloudflare 1010 拒绝，未修改站点安全策略；本机不经代理的公网 TLS 连接仍被重置。
- 本轮未改聊天、客户端或媒体下载代码。用户具体受影响设备尚未确认，MacBook 的 SSH 无法连接，不能将以上服务端与公网验证当作用户客户端的实际验收。

参数依据：[Cloudflare Tunnel 运行参数](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/#dns-resolver-addrs)。原 launchd 配置备份在 `/tmp/qqbridge-cloudflared-before-20261102.plist`。
