using Qqbridge.V1;

namespace BetterChat.Application;

// Peers 为 null 表示调用方持有同一版本，无需重读；空列表表示该版本确实没有联系人。
public sealed record DialogDirectorySnapshot(IReadOnlyList<Dialog> Dialogs, IReadOnlyList<Peer>? Peers, long PeerRevision);
public sealed record TimelineQuery(long ChatId, IReadOnlyList<long> Sequences, IReadOnlyList<long> EventIds,
    long? NewerThan, long? NewerThanTime, bool IncludeOutgoing);
// Outbox 只包含尚需显示的条目；已发送记录保留在数据库用于幂等校验，不随窗口解码。
public sealed record TimelineSnapshot(IReadOnlyList<Message> Messages, IReadOnlyList<ChatEvent> Events,
    IReadOnlyList<SendMessageRequest> Pending, IReadOnlyList<OutboxEntry> Outbox);

// 返回独立快照；页面不能持有数据库连接，也不能把延迟枚举传到后台执行。
public interface IChatReadRepository
{
    Task<IReadOnlyList<Dialog>> GetDialogsAsync(CancellationToken ct = default);
    Task<DialogDirectorySnapshot> GetDialogDirectoryAsync(CancellationToken ct = default, long knownPeerRevision = -1);
    Task<TimelineSnapshot> GetTimelineAsync(TimelineQuery query, CancellationToken ct = default);
    Task<IReadOnlyList<Peer>> GetPeersAsync(CancellationToken ct = default);
    Task<IReadOnlyList<Message>> GetMessagesAsync(long chatId, IEnumerable<long> sequences, long? newerThan, CancellationToken ct = default);
    Task<IReadOnlyList<ChatEvent>> GetEventsAsync(long chatId, IEnumerable<long> eventIds, long? newerThanTime, CancellationToken ct = default);
}
