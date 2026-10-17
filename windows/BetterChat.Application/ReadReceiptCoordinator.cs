namespace BetterChat.Core;

// UI 只提交实际读到的序号；同一会话请求合并，失败不能推进本地确认位置。
public sealed class ReadReceiptCoordinator(Func<long, long, CancellationToken, Task> send)
{
    private readonly Dictionary<long, long> confirmed = [];
    private readonly HashSet<long> running = [];
    private readonly object gate = new();
    public async Task<bool> SubmitAsync(long chat, long sequence, long serverRead, CancellationToken ct)
    {
        lock (gate)
        {
            if (chat <= 0 || sequence <= Math.Max(serverRead, confirmed.GetValueOrDefault(chat)) || !running.Add(chat)) return false;
        }
        try
        {
            await send(chat, sequence, ct).ConfigureAwait(false);
            lock (gate) confirmed[chat] = Math.Max(sequence, confirmed.GetValueOrDefault(chat));
            return true;
        }
        finally { lock (gate) running.Remove(chat); }
    }
}
