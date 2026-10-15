# BetterChat Mac 共享媒体分页 · 只读评审（Opus）

范围：`macos/BetterChat/App/Core/Services/MacSharedMediaService.swift`、`Features/Media/ViewModels/MacSharedMediaViewModel.swift`、`Features/Media/Views/MacSharedMediaStatus.swift`，以及 `ios/QQBridge/App/ChatExtras.swift` 中 `SharedMediaView` 的 macCatalyst 分支。对照了 `messages.proto` 的 `ListSharedMedia*`，以及服务端 `packages/server/src/messages/interactions.ts` 的 `sharedMedia` / `sharedMediaSorted`。没有修改、构建或运行任何东西。验收钩子（Acceptance/menu/coordinator）不在评审范围内。

## 结论：本轮 Mac 代码没有发现确定的功能缺陷

逐项核对如下。

- **两种游标语义**：只有 `sort == "time_desc"` 时发 `before_seq`，其余排序发 `offset`。服务端只要 sort 非 `time_desc`、带了 sender 或 offset 非 0，就会走 `sharedMediaSorted`，这时返回 `nextBeforeSeq = 0`，`nextOffset` 等于 offset 加本页条数，或者 0；`time_desc` 返回 `min(seq)` 或 0，`nextOffset = 0`。客户端判断「是否推进」和 `hasMore` 用的字段都和服务端对得上。`Sort.newest.api` 确实是 `"time_desc"`，不会出现「发了 offset 却走了 seq 分页、只拿到第一页」的错位。
- **切换类型或排序**：`select` 在查询变化时先 `cancel()` 换代，再清空游标、`hasLoaded`、`error`，然后加载。旧请求不管成功还是失败，都会被 `generation` 校验挡掉，也不会改动 `isLoading`/`task`。`onChange(initial:)` 和 `onAppear` 在同一次出现时都会调 `select`，第二次被 `!isLoading` 挡住，不会重复请求。
- **取消**：`onDisappear` 触发 `cancel()`。如果正在加载第一页，状态会回到 `hasLoaded=false, error=nil`，再出现时会重新加载；如果正在加载后续页，已有的项和游标都保留，回来后可以通过末项 `onAppear` 或「加载更多」按钮继续。
- **后续页失败**：游标不推进，已有项保留，`reached` 在有 error 时不自动重试，避免死循环。底部有「重试加载」，用同一个游标重新请求。第一页失败时也有空状态的重试按钮。
- **中间页为空**（`time_desc` 这一页的消息全被撤回）：游标推进，`hasMore` 仍为真；列表为空时显示「当前页没有内容 / 加载更多」，有内容时底部显示「加载更多」，都能继续翻页。
- **同一条消息有多个媒体时去重**：`identity = seq:kind:ord`，同一条消息里 ord 不同的媒体不会被合并；同一个 identity 再次出现时原地更新，`Dictionary(uniqueKeysWithValues:)` 的输入始终没有重复，不会崩溃。`time_desc` 在服务端按消息整条分页，不会把一条消息切到两页；offset 分页期间有新媒体插入导致偏移时，重复的项也会被这里吸收。
- **游标不推进的防护**：`time_desc` 要求 `next < before`（第一页 `before == 0` 时放行），offset 要求 `next > offset`，否则报错并保留原页，不会原地反复请求。

## 附：服务端已有的一个风险（不是本轮改动，仅供参考，不计入缺陷）

`interactions.ts` 的 `sharedMediaSorted` 在 `size_desc` 时按 `size desc nulls last, m.seq desc` 排序，**没有用 `r.ordinal` 兜底**。同一条消息里两个媒体大小相同时（包括两个都是 NULL），它们的先后顺序在 Postgres 里没有保证。如果这两个媒体刚好落在 offset 分页的边界上，前后两页可能返回同一个，另一个就漏掉了。Mac 端的去重能隐藏重复的那个，但补不回漏掉的那个。要修的话是在服务端的排序里加上 `r.ordinal`，不属于本轮 Mac 范围。按要求没有扩大改动，只在这里记一笔。
