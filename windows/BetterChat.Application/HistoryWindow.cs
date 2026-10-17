using Qqbridge.V1;

namespace BetterChat.Core;

// 缓存可包含搜索到的孤立旧片段；可见窗口只能由实际取过的历史页扩展。
public sealed class HistoryWindow(bool followsLatest)
{
    private readonly HashSet<long> sequences = [];
    private readonly HashSet<long> eventIds = [];
    private long liveBoundary = long.MaxValue;
    private long eventBoundary = long.MaxValue;
    public bool FollowsLatest { get; } = followsLatest;
    public bool Initialized { get; private set; }
    public bool HasOlder { get; private set; } = true;
    public bool HasNewer { get; private set; } = !followsLatest;
    public long? First => sequences.Count == 0 ? null : sequences.Min();
    public long? Last => sequences.Count == 0 ? null : sequences.Max();

    public void Start(GetHistoryResponse page)
    {
        sequences.Clear(); eventIds.Clear();
        Merge(page);
        liveBoundary = Last ?? 0;
        eventBoundary = page.Messages.Select(m => m.Time).Concat(page.Events.Select(e => e.Time)).DefaultIfEmpty(0).Max();
        Initialized = true;
        HasOlder = page.Messages.Count > 0;
        HasNewer = !FollowsLatest && page.Messages.Count > 0;
    }
    public void Extend(GetHistoryResponse page, bool older)
    {
        long? prior = older ? First : Last;
        Merge(page);
        bool advanced = older ? First < prior : Last > prior;
        if (older) HasOlder = advanced; else HasNewer = advanced;
    }
    private void Merge(GetHistoryResponse page)
    {
        foreach (var m in page.Messages) sequences.Add(m.Seq);
        foreach (var e in page.Events) eventIds.Add(e.Id);
    }
    public List<Message> ReadMessages(ILocalStore store, long chat) => Initialized
        ? store.ReadWindow("message", Message.Parser, chat, sequences.Select(seq => $"{chat}:{seq}"), FollowsLatest ? liveBoundary : null) : [];
    public BetterChat.Application.TimelineQuery Capture(long chat) => new(chat,
        Initialized ? sequences.ToArray() : [], Initialized ? eventIds.ToArray() : [],
        Initialized && FollowsLatest ? liveBoundary : null,
        Initialized && FollowsLatest ? eventBoundary : null, FollowsLatest);
    public List<ChatEvent> ReadEvents(ILocalStore store, long chat) => Initialized
        ? store.ReadWindow("event", ChatEvent.Parser, chat, eventIds.Select(id => $"{chat}:{id}"), FollowsLatest ? eventBoundary : null) : [];
    public Task<IReadOnlyList<Message>> ReadMessagesAsync(BetterChat.Application.IChatReadRepository repository, long chat, CancellationToken ct = default) => Initialized
        ? repository.GetMessagesAsync(chat, sequences.ToArray(), FollowsLatest ? liveBoundary : null, ct)
        : Task.FromResult<IReadOnlyList<Message>>([]);
    public Task<IReadOnlyList<ChatEvent>> ReadEventsAsync(BetterChat.Application.IChatReadRepository repository, long chat, CancellationToken ct = default) => Initialized
        ? repository.GetEventsAsync(chat, eventIds.ToArray(), FollowsLatest ? eventBoundary : null, ct)
        : Task.FromResult<IReadOnlyList<ChatEvent>>([]);
    public List<Message> Messages(IEnumerable<Message> cached) => Initialized
        ? cached.Where(m => sequences.Contains(m.Seq) || (FollowsLatest && m.Seq > liveBoundary)).OrderBy(m => m.Seq).ToList() : [];
    public List<ChatEvent> Events(IEnumerable<ChatEvent> cached) => Initialized
        ? cached.Where(e => eventIds.Contains(e.Id) || (FollowsLatest && e.Time > eventBoundary)).ToList() : [];
}
