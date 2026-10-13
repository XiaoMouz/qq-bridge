# packages/protocol · 客户端协议

服务端 ⇄ iOS 的协议唯一来源（protobuf + ConnectRPC，包名 `qqbridge.v1`）。同一份 proto 生成 TS（服务端用）和 Swift（iOS 用）。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 路径 | 内容 |
|---|---|
| `proto/qqbridge/v1/common.proto` | 共用类型：Peer、Dialog、Message、Segment、MediaInfo、OutgoingSegment… |
| `proto/qqbridge/v1/sync.proto` | GetState / GetDifference / Subscribe（含临时事件：typing、call、mediaReady） |
| `messages.proto` `dialogs.proto` `contacts.proto` `media.proto` `calls.proto` `auth.proto` `admin.proto` | 各个 service |
| `src/gen/` | 生成的 TS（`@bufbuild/protobuf` v2），**不要手改** |
| `../../ios/QQBridgeKit/Sources/QQBridgeProto/` | 生成的 Swift（swift-protobuf + connect-swift），**不要手改** |

## 改协议的流程

```bash
cd packages/protocol
npx buf lint && npx buf generate && npx buf generate --template buf.gen.swift.yaml
```

然后：服务端在 `packages/server/src/api/services.ts` 实现（新 RPC 不实现会编译不过）、`convert.ts` 加转换；iOS 直接用生成的类型。

## 约定

- **只加不改**：新字段用新的编号，不复用、不改已有字段的类型和含义（旧版 App 还在用）。删字段时 `reserved`。
- **buf lint 规则**：每个 RPC 的请求、响应类型独立命名（`XxxRequest` / `XxxResponse`），不能多个 RPC 共用一个响应类型。
- 注释写中文，说清楚字段的单位、空值的含义（例如「0 = 1 对 1 通话」「空 = 根目录」）。
- 只对在线设备有意义的推送放进 `SubscribeResponse` 的临时事件（不占 pts）；需要补差量的变化走版本化的行。
