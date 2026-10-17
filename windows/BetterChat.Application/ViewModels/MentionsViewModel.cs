using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record MentionsQuery(long AfterSeq);
public sealed record SeenMentionsRequest(IReadOnlyList<long> Sequences);
public sealed record SeenMentionsResult(IReadOnlyList<long> Sequences);
public sealed record MentionTarget(long Seq, uint Flags);
public sealed record MentionsPage(ListUnreadMentionsResponse Response, long AfterSeq, long EventRevision);

// 一个实例固定属于一个会话；提及已读与普通消息已读是不同的服务端状态。
public sealed class MentionsViewModel : INotifyPropertyChanged, IDisposable
{
    private const uint Direct = 1u << 5, Everyone = 1u << 6, Reply = 1u << 8;
    private readonly IUiDispatcher dispatcher;
    private readonly Dictionary<long, uint> known = [];
    private readonly HashSet<long> confirmed = [];
    private readonly Dictionary<long, long> versions = [];
    private long eventRevision;
    private MentionsPage? applied;
    private bool includeAll;
    private volatile bool disposed;
    public long ChatId { get; }
    public IReadOnlyList<MentionTarget> Items { get; private set; } = [];
    public RpcOperationViewModel<MentionsQuery, MentionsPage> Load { get; }
    public RpcOperationViewModel<SeenMentionsRequest, SeenMentionsResult> MarkSeen { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public MentionsViewModel(long chatId, bool includeAll, IMessageService api, IUiDispatcher dispatcher)
        : this(chatId, includeAll, api.ListUnreadMentionsAsync, api.MarkMentionsSeenAsync, dispatcher) { }

    public MentionsViewModel(long chatId, bool includeAll,
        Func<ListUnreadMentionsRequest, CancellationToken, Task<ListUnreadMentionsResponse>> list,
        Func<MarkMentionsSeenRequest, CancellationToken, Task<MarkMentionsSeenResponse>> markSeen, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chatId);
        ChatId = chatId; this.includeAll = includeAll; this.dispatcher = dispatcher;
        Load = new(async (query, ct) =>
        {
            long revision = 0;
            await dispatcher.InvokeAsync(() => revision = eventRevision).ConfigureAwait(false);
            var response = await list(new() { ChatId = ChatId, AfterSeq = query.AfterSeq }, ct).ConfigureAwait(false);
            return new MentionsPage(response, query.AfterSeq, revision);
        }, dispatcher, false);
        MarkSeen = new(async (request, ct) =>
        {
            long[] sequences = [];
            await dispatcher.InvokeAsync(() => sequences = request.Sequences.Where(s => s > 0 && !confirmed.Contains(s)).Distinct().ToArray()).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            if (sequences.Length > 0)
            {
                var mark = new MarkMentionsSeenRequest { ChatId = ChatId }; mark.Seqs.AddRange(sequences);
                await markSeen(mark, ct).ConfigureAwait(false);
            }
            // changed=false 也表示服务端已处理（可能另一台设备已经标记），可以确认本地结果。
            return new SeenMentionsResult(sequences);
        }, dispatcher, true);
        Load.PropertyChanged += Loaded;
        MarkSeen.PropertyChanged += Marked;
    }

    public Task<bool> LoadAsync(long afterSeq, CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(afterSeq);
        return Load.ExecuteAsync(new(afterSeq), ct);
    }
    public Task<bool> MarkSeenAsync(IEnumerable<long> sequences, CancellationToken ct = default) =>
        MarkSeen.ExecuteAsync(new(sequences.ToArray()), ct);

    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || Load.State != OperationState.Succeeded || Load.Result is not { } result || ReferenceEquals(applied, result)) return;
        applied = result;
        var returned = result.Response.Mentions.Where(m => m.Seq > result.AfterSeq && m.Seq > 0)
            .GroupBy(m => m.Seq).ToDictionary(g => g.Key, g => g.Aggregate(0u, (flags, m) => flags | m.Flags));
        // 后端按 seq 倒序最多返回 200 项；满页只能证明最小返回序号以上的缺席项已消失。
        long lower = result.Response.Mentions.Count >= 200 && returned.Count > 0 ? returned.Keys.Min() : result.AfterSeq == long.MaxValue ? long.MaxValue : result.AfterSeq + 1;
        if (result.AfterSeq != long.MaxValue)
            foreach (long seq in known.Keys.Where(seq => seq >= lower && seq > result.AfterSeq
                && !returned.ContainsKey(seq) && versions.GetValueOrDefault(seq) <= result.EventRevision).ToArray())
            { known.Remove(seq); versions.Remove(seq); }
        foreach (var mention in returned)
            if (!confirmed.Contains(mention.Key))
                known[mention.Key] = versions.GetValueOrDefault(mention.Key) > result.EventRevision
                    ? known.GetValueOrDefault(mention.Key) | mention.Value : mention.Value;
        Publish();
    }
    private void Marked(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || MarkSeen.State != OperationState.Succeeded || MarkSeen.Result is not { } result) return;
        foreach (long seq in result.Sequences) { confirmed.Add(seq); known.Remove(seq); versions.Remove(seq); }
        Publish();
    }
    public Task SetIncludeAllAsync(bool value) => dispatcher.InvokeAsync(() =>
    {
        if (disposed) return;
        includeAll = value; Publish();
    });
    public Task NoteIncomingAsync(Message message, bool isOwn, bool atBottom)
    {
        // 调度前取值，不持有同步层仍可能修改的 protobuf 对象。
        long chat = message.ChatId, seq = message.Seq;
        uint flags = message.Flags;
        bool recalled = message.State == MessageState.Recalled;
        return dispatcher.InvokeAsync(() =>
        {
            if (disposed || chat != ChatId || seq <= 0) return;
            if (recalled) { confirmed.Add(seq); known.Remove(seq); versions.Remove(seq); Publish(); return; }
            if (isOwn || atBottom || confirmed.Contains(seq) || (flags & (Direct | Everyone | Reply)) == 0) return;
            versions[seq] = ++eventRevision;
            known[seq] = known.GetValueOrDefault(seq) | flags; Publish();
        });
    }
    private void Publish()
    {
        uint mask = Direct | Reply | (includeAll ? Everyone : 0);
        Items = known.Where(p => (p.Value & mask) != 0).OrderByDescending(p => p.Key).Select(p => new MentionTarget(p.Key, p.Value)).ToArray();
        PropertyChanged?.Invoke(this, new(nameof(Items)));
    }
    public void Dispose()
    {
        disposed = true; Load.PropertyChanged -= Loaded; MarkSeen.PropertyChanged -= Marked;
        Load.Dispose(); MarkSeen.Dispose();
    }
}
