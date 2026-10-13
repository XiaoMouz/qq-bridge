# tools · 运维与研究脚本

在仓库根目录运行。总规矩见根目录 [AGENTS.md](../AGENTS.md)。

| 脚本 | 用途 |
|---|---|
| `qq-plugin.sh` | 插件：`deploy`（构建 → 拷进容器 → 热重载，不重新登录 QQ）、`reload`、`calls on|off`、`set KEY VALUE`（开关文件 `deploy/data/napcat-config/qqbridge.env`） |
| `qq.sh` | 调试 QQ 容器：`status`、`call`、`accept`、`record`（录对方的声音）、`tone`（往 QQ 麦克风放测试音）、`get <插件路径>` |
| `qface-sync.py` | 同步 QQ 表情资源（来源 koishijs/QFace）到 `deploy/data/qface`；`--ios` 同时更新 App 的 `Resources/QQFaces` 和 `QQFaceNames.swift`。QQ 出新表情时重跑 |
| `call-e2e.sh` | 通话音频链路自测（不登录 QQ）：假 iPhone ⇄ LiveKit ⇄ 网关 ⇄ PulseAudio 回环，测往返时延 |
| `analyze-capture.mjs` | 分析插件抓的 JSONL（P0 问题：seq 语义、媒体链接有效期等） |

## 约定

- 插件和 AV Host 的控制口只在容器内回环，脚本都经 `docker exec` 访问；令牌从容器里的 `/run/qqbridge/control.token` 读，**不要打印**。
- 新的一次性调试脚本放 scratchpad（会话的临时目录），确实反复用的再放这里，并在上表加一行。
