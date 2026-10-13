# packages/domain · 领域模型

服务端（以及测试）共用的纯 TypeScript 类型和规则，不依赖数据库、网络。总规矩见根目录 [AGENTS.md](../../AGENTS.md)。

## 结构

| 文件 | 内容 |
|---|---|
| `src/types.ts` | 领域模型（与 Milky 语义对齐：会话 = scene + peerId，消息主键 = 会话内 seq）、Segment、MediaInfo |
| `src/segments.ts` | 消息段工具（纯文本预览 `plainText` 等） |
| `src/events.ts` | 服务事件（灰条）与表情回应 |
| `src/outgoing.ts` | 外发消息段与校验（媒体只引用 sha256） |
| `src/retention.ts` | 原件保留策略（单会话 > 会话类型 > 全局，多会话引用取最久） |
| `src/storage.ts` | 按会话的存储占用（全量参考实现，属性测试用） |
| `src/sync-rules.ts` | 客户端应用更新的规则（pts 连续性） |

## 约定

- 上游适配器（`server/src/upstream/napcat/map.ts`）把 OneBot / NT 原始结构转成这里的类型；服务端其余部分只认这些类型。
- 改了类型要同时看 `server/src/sync/rows.ts`、`api/convert.ts` 和 proto 是否要跟着改。
- `npx tsc --noEmit -p . && npx vitest run`
