# packages/av-host · 通话引擎宿主

QQ 自带的 Electron 以第二个进程启动（`deploy/qq/loadNapCat.js` 在 `QQBRIDGE_AV_HOST=1` 时分流到 `host.cjs`），在隐藏窗口里用 `--register-pepper-plugins` 加载 QQ 安装目录的 `libAVSDKPlugin.so`（通话引擎）。插件发来的指令 `postMessage` 给引擎，引擎的输出转回插件。改写自 maibot-qq-voice-call（GPL-3.0，自用不分发）。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 文件

| 文件 | 内容 |
|---|---|
| `host.cjs` | Electron 主进程：回环 HTTP 控制口（`POST /v1/invoke {command, params}`，Bearer 令牌）、指令白名单 `DEFAULT_ALLOWED_COMMANDS` |
| `host.html` | 隐藏窗口：`<embed type="application/x-ppapi-avSDK">`，转发 `message` 事件 |

## 约定

- 指令号和参数见 [docs/calls.md](../../docs/calls.md)。**新用到一个指令要加进白名单**（研究模式 `QQBRIDGE_LAB=1` 放开全部）。
- 部署：镜像构建时拷进 `/app/av-host/`；改完临时生效用 `docker cp packages/av-host/host.cjs qqbridge-qq:/app/av-host/host.cjs` 再 `docker exec qqbridge-qq supervisorctl -c /etc/qqbridge/supervisord.conf restart avhost`（会断掉进行中的通话；2026-10-13 实测重启后插件会重新登录引擎，通话正常）。长期要重建镜像。
- 由 supervisord 守护（`deploy/qq/run-avhost.sh`），`QQBRIDGE_CALLS` 关闭时不启动。
