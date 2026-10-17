namespace BetterChat.Application;

// 活跃会话是最新意图，不是可靠消息队列。串行发送，并丢弃还未发出的旧意图。
public sealed class ActiveChatCoordinator(Func<long, CancellationToken, Task> send)
{
    private readonly SemaphoreSlim serial = new(1, 1);
    private long revision;
    public Task SetAsync(long chat, CancellationToken ct = default)
    {
        if (chat < 0 || chat > (1L << 53) - 1) throw new ArgumentException("活跃会话标识无效。");
        long requestRevision = Interlocked.Increment(ref revision);
        return RunAsync(chat, requestRevision, ct);
    }
    private async Task RunAsync(long chat, long requestRevision, CancellationToken ct)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            ct.ThrowIfCancellationRequested();
            if (requestRevision != Interlocked.Read(ref revision)) return;
            await send(chat, ct).ConfigureAwait(false);
        }
        finally { serial.Release(); }
    }
}
