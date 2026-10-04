# iOS 客户端

设计见 [docs/design.md](../docs/design.md) 第 6 节。

## QQBridgeKit（与界面无关的部分，已完成）

Swift 包，不依赖 UIKit / SwiftUI。App 和通知、分享扩展共用。在 Mac 上用 `swift test` 就能测，不需要 Xcode。

| 目录 | 内容 |
|---|---|
| `Sources/QQBridgeProto` | 由 `packages/protocol` 用 buf 生成：swift-protobuf 消息 + connect-swift 客户端。改了 proto 后运行 `pnpm --filter @qqbridge/protocol generate:swift`，不要手改。 |
| `Client/APIClient.swift` | ConnectRPC（二进制 protobuf），设备令牌放在请求头里。`SyncAPI` 是同步引擎依赖的那部分接口，测试时换成假服务端。 |
| `Store/LocalStore.swift` | GRDB 本地库（放在 App Group 里）。每行存 protobuf 原文，加上查询和排序要用的列。每个会话记 `chat_pts` 和已加载的连续 seq 区间。支持按"每个会话最近 2000 条 / 30 天"裁剪。 |
| `Sync/SyncEngine.swift` | actor。GetDifference 追平 → 预取最近 30 个会话的首屏 → Subscribe 实时更新。按 pts / chat_pts 规则应用更新，缺号时拉差量补齐。断线按 1→30 秒退避重连。令牌失效时停下，提示重新登录。另外提供打开会话（首屏或补变化）和往上翻页。 |
| `Media/MediaCache.swift` | 按 sha256 缓存，下载后校验，同一内容同时只下一次。上限默认 2GB，保留期默认 7 天，超期的先删，再按最久没用的删。可以按会话清理。视频走签名链接边下边播。 |
| `Outbox/Sender.swift` | 发送：本地先放进发件箱显示"发送中"，网络失败用同一个 `client_random_id` 重试，不会重复发出。 |
| `Session/Session.swift` | 把上面的部件装配起来。设备令牌放在钥匙串（App Group 共享）。负责登录和退出（退出时吊销令牌、清缓存）。 |

```bash
cd ios/QQBridgeKit && swift test
```

命令行验收：用真实服务端把客户端主流程走一遍。密码在终端里输入；结束时会吊销这次登录产生的设备令牌。

```bash
cd ios/QQBridgeKit && swift run qqbridge-check --server http://127.0.0.1:8080 --user owner
```

## App（等 Xcode 27）

需要先完成设计里的 P-1 环境准备：安装 Xcode 27，并腾出磁盘空间（Xcode 加上 iOS 模拟器约 25GB）。界面部分包括：SwiftUI 搭整体框架，聊天页用 UIKit 的 `UICollectionView`，以及 Liquid Glass、通知扩展、CallKit 和 LiveKit。
