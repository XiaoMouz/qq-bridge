# ios/QQBridgeKit · Swift 包（与界面无关的部分）

App 和通知扩展共用，不依赖 UIKit / SwiftUI，`swift test` 就能测。各部分说明见 [ios/README.md](../README.md)。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 路径 | 内容 |
|---|---|
| `Sources/QQBridgeProto/` | 由 `packages/protocol` 生成的 swift-protobuf + connect-swift，**不要手改**（改 proto 后重新生成） |
| `Sources/QQBridgeKit/Client/APIClient.swift` | ConnectRPC 客户端（设备令牌在请求头）、表情资源下载 `qfaceAsset` |
| `Sources/QQBridgeKit/Store/` | GRDB 本地库（App Group）：会话、消息（存 protobuf 原文 + 索引列）、`Observations.swift`（`observeMessage` / `observeDialogs`）、存储浏览 |
| `Sources/QQBridgeKit/Sync/SyncEngine.swift` | actor：GetDifference 追平 → Subscribe 实时；发出 `SyncEvent`（连接状态、正在输入、通话、mediaReady） |
| `Sources/QQBridgeKit/Media/MediaCache.swift` | 按 sha256 缓存（上限、保留期、按会话清理、`cachedSet` / `remove`），签名链接边下边播 |
| `Sources/QQBridgeKit/Outbox/` | 发送（client_random_id 去重重试）、分块上传 |
| `Sources/QQBridgeKit/Session/Session.swift` | 装配上面的部件；令牌存钥匙串 |
| `Sources/qqbridge-check/` | 命令行验收（用真实服务端走一遍主流程）；`SyncEvent` 加了新类型要在这里的 switch 里补上 |

## 约定

- 新的临时事件：`sync.proto` 的 `SubscribeResponse` 加字段 → `SyncEngine` 的 `SyncEvent` 加一个 case 并转发 → App 的 `AppModel` 事件循环处理 → `qqbridge-check` 的 switch 补上。
- 改完在 App 工程里构建一遍（App 依赖这个包）；`Package.resolved` 构建后会被改，记得还原。
- `cd ios/QQBridgeKit && swift test`
