# Opus 5.5 附件状态复核（2026-10-15）

Claude Code 使用 auto 权限模式，只读审查源码。初次指出排队不可移除、迟到失败重复分配引用、服务端排队被本地降级三项，均已修正；下文为最终复核。Codex 随后确认最终 18 项应用检查、34 项 Swift 包测试及 iOS 构建通过。真实 SwiftUI 宿主测试位于 AttachmentOutboxTests 的 swiftUIObserverRestartsForBatchCompletionAndNewAttachments，不将首轮未看到该新增测试的说法作为最终结论。

## 复核结论

这次的三处修正没有引入新的阻塞问题。我只读了相关代码，没有改文件，也没有跑测试。最终测试结果还要以你那边重跑的为准。

## 逐项确认

**问题 1：`.queued` 排队状态**
- 观察到 pending 或 sending 时，现在设成 `.queued`，不再设成 `.uploading`。
- 附件栏只在 `.uploading` 时隐藏 ×，所以排队中的附件可以移除，之前那种「一直转圈、移不掉」的情况不会再出现。
- 帮助说明写的是「不取消已提交的发送」，和实际行为一致。
- 状态是 `.queued` 但记录不见了，会转成可重试的 failed（`AttachmentSending.swift:117`）。这一步在 `isSending` 保护之前执行；不过批次里的附件已经先被设成 `.uploading`，所以不会误伤正在发送的附件。
- 进入排队时会把这个附件 ID 放进 `resolved`，只清掉它自己的错误，不影响其他错误。

**问题 2：`AttachmentDelivery` 共享确认标记**
- 它是 class，`Attachment` 结构体被复制后仍然指向同一个对象。所以在 `reconcile` 的 `compactMap` 里设 `confirmed`，`send` 里拿着的 `current` 也能看到。
- 它标了 `@MainActor`，读写都在主线程上，没有并发问题。
- 只要 `submittedMessage` 在 RPC 前已经赋值，迟到失败就会按本批引用来判断是否已被消耗，逻辑正确。

**问题 3：`Sender.send` 对已收下的条目直接返回**
- `pts > 0` 并且状态是 pending 或 sending 时，直接返回已有条目。这样既不会写本地的 `localAttempt`，也不会在网络失败后把服务端的排队状态降成 failed。
- 气泡上的重发走的是 `resend` → `submit`，不受这个改动影响。

## 一个不阻塞的小点

`sendAll` 只排除 `.uploading`（`ChatScreen.swift:1182`），所以 `.queued` 的附件会被并进下一次发送。不会因此多发消息，有三种情况：

- **pts > 0：** `Sender` 直接返回已有条目，不发请求，附件栏把它移走。
- **pts = 0（例如气泡重发的请求还在途中）：** 会再发一次同 ID 的 RPC，服务端按 ID 去重。
- **冻结的引用正好等于本批引用：** 这需要用户在上一批发完后又选了同一条引用，概率很低。这时会返回 true，把本批引用当作已用掉，后面那条文字就不带引用了。

如果想让行为更干净，可以在 `sendAll` 的过滤条件里把 `.queued` 一起排除。不改也可以接受。
