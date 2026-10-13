# AGENTS.md · QQ Bridge（BetterChat）

给在这个仓库里干活的 agent 看的总入口。先读这一页，再读你要改的那个目录里的 `AGENTS.md`。**回复和文档都用简体中文。**

## 这是什么

个人自用（不公开、不商用）的 QQ 系统：

- **服务端**（TypeScript，Postgres，ConnectRPC）：基于 NapCat 持续存档 QQ 消息和媒体（按 sha256 去重），Telegram 式多设备增量同步（pts / chat_pts、Subscribe 流）。
- **NapCat 插件**：在 QQ 进程里采集事件、执行动作，还有通话信令桥。
- **通话桥**：AV Host（加载 QQ 自己的通话引擎）+ PulseAudio + call-gateway + LiveKit，让 iPhone 接打 QQ 语音电话。
- **iOS App「BetterChat」**（Swift 6，iOS 26+）：会话、聊天、媒体、通话（CallKit）、通知扩展。

全部跑在一台 Mac mini（M2）上：Postgres、QQ（NapCat）、LiveKit、call-gateway 在 OrbStack 里，服务端是 launchd 常驻进程。

## 目录与各自的 AGENTS.md

| 目录 | 内容 | 说明 |
|---|---|---|
| `packages/server` | 服务端 | [AGENTS.md](packages/server/AGENTS.md) |
| `packages/napcat-plugin-qqbridge` | NapCat 插件（采集、动作、通话信令） | [AGENTS.md](packages/napcat-plugin-qqbridge/AGENTS.md) |
| `packages/protocol` | proto（客户端协议的唯一来源）+ 生成的 TS | [AGENTS.md](packages/protocol/AGENTS.md) |
| `packages/domain` | 领域类型、消息段、同步规则（服务端和插件共用） | [AGENTS.md](packages/domain/AGENTS.md) |
| `packages/av-host` | 通话引擎宿主（QQ 的 Electron 里加载 libAVSDKPlugin.so） | [AGENTS.md](packages/av-host/AGENTS.md) |
| `packages/call-gateway` | PulseAudio ⇄ LiveKit 的媒体桥 | [AGENTS.md](packages/call-gateway/AGENTS.md) |
| `ios/QQBridge` | iOS App（XcodeGen 工程、通知扩展） | [AGENTS.md](ios/QQBridge/AGENTS.md) |
| `ios/QQBridgeKit` | Swift 包：API 客户端、本地库、同步、媒体缓存、生成的 proto | [AGENTS.md](ios/QQBridgeKit/AGENTS.md) |
| `deploy` | docker compose、QQ 镜像、launchd、LiveKit 配置；`deploy/data` 是运行数据 | [AGENTS.md](deploy/AGENTS.md) |
| `tools` | 运维脚本（插件部署、QQ 调试、表情同步） | [AGENTS.md](tools/AGENTS.md) |
| `macos` | macOS 版 BetterChat（Mac Catalyst，另一路在做，尚未提交） | [README](macos/README.md) |
| `fixtures` | 测试样本（脱敏） | |

## 文档索引

| 文档 | 什么时候看 |
|---|---|
| [docs/design.md](docs/design.md) | 总体设计：架构、表结构、同步模型、媒体存储、推送、通话方案、里程碑 |
| [docs/changelog.md](docs/changelog.md) | 修改记录：按时间和功能分组，带 commit；查「某功能是哪次、为什么这么改」 |
| [docs/lessons.md](docs/lessons.md) | **教训**：犯过三次的错误和对策。写代码前、评审前看 |
| [docs/calls.md](docs/calls.md) | 通话桥实测：引擎指令表、内核回调含义、调试方法 |
| [README.md](README.md) | 部署、启动、P0 验证步骤、常见问题 |
| [ios/README.md](ios/README.md) | QQBridgeKit 各部分说明、命令行验收 |

## 常用命令

```bash
# 服务端
cd packages/server && npx tsc --noEmit -p . && npx vitest run
launchctl kickstart -k gui/$(id -u)/com.xiaomouz.qqbridge.server   # 重启服务端
tail -f ~/Library/Logs/qqbridge/server.log

# 插件（热重载，不用重新登录 QQ）
sh tools/qq-plugin.sh deploy

# 改了 proto
cd packages/protocol && npx buf lint && npx buf generate && npx buf generate --template buf.gen.swift.yaml

# iOS（模拟器构建；加了新 Swift 文件要先 xcodegen）
cd ios/QQBridge && xcodegen generate && xcodebuild -project BetterChat.xcodeproj -scheme BetterChat \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build
git checkout -- ios/QQBridgeKit/Package.resolved   # 构建 / 打包后还原

# 数据库
docker exec qqbridge-postgres psql -U qqbridge -d qqbridge
```

## 规矩

- **提交**：`git -c commit.gpgsign=false commit`，中文说明（写清楚改了什么、为什么），**不加 Co-Authored-By**。一个功能一个提交。
- **版本**：没有用户明确说「发布 / 打包」就不改版本号、不打包、不开 Organizer。要发布时升小版本（1.12 → 1.13）、构建号 +1；同版本重打只加构建号。打包后还原 `Package.resolved`。
- **秘密**：不打印 `deploy/.env`、APNs `.p8` 的内容；不替用户登录、不创建设备令牌。
- **测试**：发测试消息只在测试群「Something」（chat 153，群号 521409608）；不给用户手机（设备 5）发测试推送，模拟器是设备 7（sandbox）。
- **别碰**：`~/Workspace/qq-bot` 是用户另一套 LLBot/NoneBot 机器人（QQ 3865801565「BOT」，测试通话时用户用它当另一个号）。不改它、不复用它，也不要用它的号扫 NapCat。NapCat 登的是主号 1114096791。
- **需要用户配合的**（打电话、扫码、发群语音）：说清楚要做什么，等用户回复再看结果，不要猜。
- **会动到用户在线状态的操作**（重启 NapCat、重载 AV Host）先问；重启 NapCat 可能要重新扫码。

## 代码准则（来自 [lessons.md](docs/lessons.md)）

- **不猜 QQ / NapCat 字段的含义**：先抓原始数据（插件 capture 目录、`/v1/debug/raw`、`/v1/debug/rpc`），对照至少两个真实场景再写判断，条件写成白名单并注明抓到的日期和场景。（L2）
- **Swift 并发**：系统回调里先取出 Sendable 的值再进 MainActor；确实安全时用 `nonisolated(unsafe)` 并写注释；等事件用 continuation，不传 AsyncStream 迭代器。（L1）
- **SwiftUI 尺寸**：装饰背景放 `.background`；「最多 N 宽、内容多少就多宽、超了换行」用 `CappedWidth`；改完看长短两种内容。（L4）
- **模拟器测试**：用 `-debugJump chatId:seq`、置顶会话或 `simctl push` 打开会话，不按列表位置点；截图像素 ÷ 3 = 点坐标；每步截图确认。（L3）
- **推送优先于轮询**：等服务端结果用 Subscribe 临时事件（如 `mediaReady`、`call`）或本地库观察，轮询只做兜底。
- **长期状态要经得起热重载**：插件里的监听、定时器、队列，按「被重载很多次」设计。
- **有状态机的记录要能收尾**：超时、被新的替换时，旧的要记为结束。
- **注释**：中文，写「为什么」和「哪天实测的结论」，不写显而易见的「做什么」。和周围代码的注释密度、命名、习惯保持一致。

## 教训的维护规则

**同一类错误犯了三次，就写进 [docs/lessons.md](docs/lessons.md)**：现象、原因、以后怎么做、出现过的地方，并在上面的「代码准则」里加一行摘要。犯了一两次的先记在 lessons.md 的「观察中」，再出现时补上次数，满三次升级。
