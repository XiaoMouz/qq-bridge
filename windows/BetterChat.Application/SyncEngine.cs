using Qqbridge.V1;

namespace BetterChat.Core;

public sealed class SyncEngine(IBridgeApi api, ILocalStore store)
{
    private readonly SemaphoreSlim serial = new(1);
    public event Action<string>? Status;
    public event Action<SubscribeResponse>? Ephemeral;
    public event Func<SubscribeResponse, CancellationToken, Task>? EphemeralReceived;
    public event Action<long>? ChatInvalidated;
    public event Action<Message>? StreamMessageReceived;
    public IReadOnlySet<long> OwnUsers { get; private set; } = new HashSet<long>();

    // 登录时已经拿到过账号列表：先用它填上「自己的账号」。否则在同步循环第一次 GetState 之前打开会话，
    // 自己发的消息会被当成别人的（显示在左边、没有撤回，2026-10-17 实测）。同步拿到的列表随后会覆盖它。
    public void SeedOwnUsers(IEnumerable<long> users)
    {
        if (OwnUsers.Count == 0) OwnUsers = users.Where(u => u > 0).ToHashSet();
    }

    public async Task RunAsync(CancellationToken ct)
    {
        int delay = 1;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                Status?.Invoke("正在连接…");
                var state = await api.GetStateAsync(new(), ct);
                OwnUsers = state.QqAccounts.Select(a => a.Uin).ToHashSet();
                await serial.WaitAsync(ct);
                try
                {
                    await CatchUp(ct); await RepairChats(ct);
                    try { await PrefetchCore(ct); }
                    catch (RpcException e) when (e.Code == "unauthenticated") { throw; }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (Exception) { Status?.Invoke("首屏预取失败，打开会话时重试"); }
                }
                finally { serial.Release(); }
                Status?.Invoke("已连接"); delay = 1;
                await foreach (var update in api.SubscribeAsync(new() { Pts = store.Cursor() }, ct))
                {
                    await serial.WaitAsync(ct);
                    try { ct.ThrowIfCancellationRequested(); await Consume(update, ct); }
                    finally { serial.Release(); }
                }
                throw new IOException("同步连接已结束");
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (RpcException e) when (e.Code == "unauthenticated") { Status?.Invoke("设备令牌已失效，请重新连接"); return; }
            catch (Exception)
            {
                if (ct.IsCancellationRequested) return;
                Status?.Invoke($"连接中断，{delay} 秒后重试");
                try { await Task.Delay(TimeSpan.FromSeconds(delay), ct); } catch (OperationCanceledException) { return; }
                delay = Math.Min(delay * 2, 30);
            }
        }
    }
    private async Task CatchUp(CancellationToken ct)
    {
        while (true)
        {
            long previous = store.Cursor();
            var d = (await api.GetDifferenceAsync(new() { Pts = previous, Limit = 500 }, ct)).Difference;
            ct.ThrowIfCancellationRequested();
            // 外部重置或写入后旧响应已不对应当前快照，尤其不能用旧 tooLong 清库。
            if (store.Cursor() != previous) continue;
            if (d is null) throw new IOException("全局同步响应缺少差量");
            if (d.TooLong)
            {
                // 0 已表示全量，继续重置无法修复服务端仍返回 tooLong 的情况。
                if (previous == 0) throw new IOException("全量同步仍返回游标过期");
                store.Reset(); continue;
            }
            if (d.Pts < previous || (!d.IsFinal && d.Pts == previous))
                throw new IOException("全局同步游标未推进");
            store.Apply(d);
            NotifyDialogs(d);
            if (d.IsFinal) break;
        }
    }
    private async Task RepairChats(CancellationToken ct, IEnumerable<Dialog>? changed = null)
    {
        // 连续实时更新只检查受影响的会话；全量扫描留给重连与补差恢复。
        // 重读已提交的快照，不能让迟到的低版本 Dialog 决定补差目标。
        var dialogs = changed is null ? store.Dialogs : changed.Select(d => d.ChatId).Distinct()
            .Select(store.ReadDialog).OfType<Dialog>().ToList();
        var wanted = dialogs
            .OrderByDescending(d => d.Pinned)
            .ThenByDescending(d => d.UnreadCount > 0)
            .ThenByDescending(d => d.TopTime)
            .Select(d => new ChatSyncState { ChatId = d.ChatId, ChatPts = store.Cursor("chat:" + d.ChatId) })
            .Where(c => c.ChatPts > 0)
            .ToArray();
        var targets = dialogs.ToDictionary(d => d.ChatId, d => d.ChatPts);
        foreach (var batch in wanted.Where(c => c.ChatPts < targets[c.ChatId]).Chunk(100))
        {
            ct.ThrowIfCancellationRequested();
            var request = new GetChatDifferencesRequest { PerChatLimit = 30 };
            request.Chats.AddRange(batch);
            var response = await api.GetChatDifferencesAsync(request, ct);
            ct.ThrowIfCancellationRequested();
            var requested = batch.ToDictionary(c => c.ChatId, c => c.ChatPts);
            foreach (var result in response.Chats)
            {
                ct.ThrowIfCancellationRequested();
                if (!requested.Remove(result.ChatId, out long previous)) continue;
                // 仅接受本批请求对应的快照，避免重复响应或外部写入后旧快照清除新窗口。
                if (store.Cursor("chat:" + result.ChatId) != previous)
                {
                    if (store.Cursor("chat:" + result.ChatId) < targets[result.ChatId]) await LoadChatCore(result.ChatId, ct);
                    continue;
                }
                if (result.ChatPts < previous) throw new IOException("批量同步游标回退");
                store.ApplyChat(result.ChatId, result.ChatPts, result.Messages, result.Events, result.TooLong);
                if (!result.IsFinal || result.ChatPts < targets[result.ChatId]) await LoadChatCore(result.ChatId, ct);
            }
            // 协议允许省略无权访问或已删除的会话；不据此推断删除，也不对其无限补拉。
        }
    }
    public async Task PrefetchAsync(CancellationToken ct = default)
    {
        await serial.WaitAsync(ct);
        try { await PrefetchCore(ct); }
        finally { serial.Release(); }
    }
    private async Task PrefetchCore(CancellationToken ct)
    {
        // 与 Apple 默认的 30 个会话对齐，只取列表优先级最高的范围，不下载全部存档。
        var wanted = store.Dialogs.OrderByDescending(d => d.Pinned)
            .ThenByDescending(d => d.UnreadCount > 0).ThenByDescending(d => d.TopTime)
            .Take(30).Where(d => store.Cursor("chat:" + d.ChatId) == 0)
            .ToDictionary(d => d.ChatId, d => d.ChatPts);
        if (wanted.Count == 0) return;
        var request = new GetChatDifferencesRequest { PerChatLimit = 30 };
        request.Chats.AddRange(wanted.Keys.Select(id => new ChatSyncState { ChatId = id }));
        var response = await api.GetChatDifferencesAsync(request, ct);
        ct.ThrowIfCancellationRequested();
        foreach (var result in response.Chats)
        {
            ct.ThrowIfCancellationRequested();
            if (!wanted.Remove(result.ChatId, out long target)) continue;
            if (store.Cursor("chat:" + result.ChatId) != 0) continue;
            if (result.ChatPts < 0 || (!result.IsFinal && result.ChatPts == 0))
                throw new IOException("首屏预取游标未推进");
            var page = new GetHistoryResponse { ChatPts = result.ChatPts };
            page.Messages.AddRange(result.Messages); page.Events.AddRange(result.Events);
            if (!store.TryApplyFirstScreen(result.ChatId, page, result.TooLong)) continue;
            if (!result.IsFinal || result.ChatPts < target) await LoadChatCore(result.ChatId, ct);
        }
    }
    public async Task LoadChatAsync(long chat, CancellationToken ct)
    {
        await serial.WaitAsync(ct);
        try { await LoadChatCore(chat, ct); }
        finally { serial.Release(); }
    }
    private async Task LoadChatCore(long chat, CancellationToken ct)
    {
        while (true)
        {
            long previous = store.Cursor("chat:" + chat);
            var d = await api.GetChatDifferenceAsync(new() { ChatId = chat, ChatPts = previous, Limit = 100 }, ct);
            ct.ThrowIfCancellationRequested();
            if (d.ChatPts < previous || (!d.IsFinal && d.ChatPts == previous))
                throw new IOException("会话同步游标未推进");
            store.ApplyChat(chat, d.ChatPts, d.Messages, d.Events, d.TooLong);
            if (d.IsFinal) return;
        }
    }
    private async Task Consume(SubscribeResponse u, CancellationToken ct)
    {
        long pts = u.EventCase switch
        {
            SubscribeResponse.EventOneofCase.Dialog => u.Dialog.Pts,
            SubscribeResponse.EventOneofCase.Peer => u.Peer.Pts,
            SubscribeResponse.EventOneofCase.Tombstone => u.Tombstone.Pts,
            SubscribeResponse.EventOneofCase.Outbox => u.Outbox.Pts,
            _ => 0
        };
        if (pts > 0)
        {
            if (pts <= store.Cursor()) return;
            if (pts != store.Cursor() + 1) { await Task.Delay(500, ct); await CatchUp(ct); await RepairChats(ct); return; }
            var d = new Difference { Pts = pts, IsFinal = true };
            if (u.Dialog is not null) d.Dialogs.Add(u.Dialog.Dialog);
            if (u.Peer is not null) d.Peers.Add(u.Peer.Peer);
            if (u.Tombstone is not null) d.Tombstones.Add(u.Tombstone.Tombstone);
            if (u.Outbox is not null) d.Outbox.Add(u.Outbox.Entry);
            store.Apply(d); NotifyDialogs(d); await RepairChats(ct, d.Dialogs); return;
        }
        if (u.Difference is { } diff)
        {
            if (diff.TooLong) { store.Reset(); throw new IOException("需要重建同步快照"); }
            store.Apply(diff); NotifyDialogs(diff); await RepairChats(ct, diff.Dialogs);
        }
        else if (u.ChatMessage is { } m)
        {
            await ChatUpdate(m.ChatId, m.ChatPts, [m.Message], [], ct);
            // 未加载的会话也可能有打开的提及页面；失效信号不要求消息已入本机缓存。
            ChatInvalidated?.Invoke(m.ChatId);
            StreamMessageReceived?.Invoke(m.Message.Clone());
        }
        else if (u.ChatEvent is { } e) await ChatUpdate(e.ChatId, e.ChatPts, [], [e.Event], ct);
        else if (u.Heartbeat is { } h && h.Pts > store.Cursor()) { await CatchUp(ct); await RepairChats(ct); }
        else if (u.Resync is not null) throw new IOException("服务端要求重新同步");
        else
        {
            if (EphemeralReceived is { } received)
                foreach (Func<SubscribeResponse, CancellationToken, Task> handler in received.GetInvocationList())
                    await handler(u, ct);
            Ephemeral?.Invoke(u);
        }
    }
    private void NotifyDialogs(Difference difference)
    {
        var deleted = difference.Tombstones.Where(t => t.Entity is "dialog" or "chat")
            .Select(t => long.TryParse(t.Key, out long chat) ? chat : 0).Where(chat => chat > 0);
        foreach (long chat in difference.Dialogs.Select(d => d.ChatId).Concat(deleted).Distinct()) ChatInvalidated?.Invoke(chat);
    }
    private async Task ChatUpdate(long chat, long pts, Message[] messages, ChatEvent[] events, CancellationToken ct)
    {
        long current = store.Cursor("chat:" + chat);
        if (current == 0 || pts <= current) return;
        if (pts != current + 1) { await Task.Delay(500, ct); await LoadChatCore(chat, ct); }
        else store.ApplyChat(chat, pts, messages, events);
    }
}
