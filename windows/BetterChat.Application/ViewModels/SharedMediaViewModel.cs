using System.ComponentModel;
using Google.Protobuf;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public enum SharedMediaOrder { Newest, Oldest, Largest, Sender }
public sealed record SharedMediaPageQuery;
public sealed record SharedMediaPage(ListSharedMediaResponse Response, long BeforeSeq, int Offset);

// 筛选条件固定在实例中；切换筛选创建新实例并释放旧实例，迟到响应不会跨条件发布。
public sealed class SharedMediaViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly List<SharedMedia> items = [];
    private readonly Dictionary<(long Seq, MediaKind Kind, string Part), int> positions = [];
    private readonly bool offsetPaging;
    private SharedMediaPage? applied;
    private long nextBefore;
    private int nextOffset;
    public long ChatId { get; }
    public IReadOnlyList<SharedMedia> Items { get; private set; } = [];
    public bool HasMore { get; private set; } = true;
    public string? PaginationError { get; private set; }
    public RpcOperationViewModel<SharedMediaPageQuery, SharedMediaPage> Load { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public SharedMediaViewModel(long chatId, IEnumerable<MediaKind> kinds, SharedMediaOrder order, long senderId,
        IMessageService api, IUiDispatcher dispatcher)
        : this(chatId, kinds, order, senderId, api.ListSharedMediaAsync, dispatcher) { }

    public SharedMediaViewModel(long chatId, IEnumerable<MediaKind> kinds, SharedMediaOrder order, long senderId,
        Func<ListSharedMediaRequest, CancellationToken, Task<ListSharedMediaResponse>> load, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chatId);
        ArgumentOutOfRangeException.ThrowIfNegative(senderId);
        ChatId = chatId;
        var filter = kinds.Distinct().ToArray();
        string sort = order switch
        {
            SharedMediaOrder.Newest => "time_desc", SharedMediaOrder.Oldest => "time_asc",
            SharedMediaOrder.Largest => "size_desc", SharedMediaOrder.Sender => "sender",
            _ => throw new ArgumentOutOfRangeException(nameof(order))
        };
        // 2026-10-16 对照服务端 interactions.sharedMedia：senderId 非零也进入 offset 分支。
        offsetPaging = order != SharedMediaOrder.Newest || senderId != 0;
        Load = new(async (_, ct) =>
        {
            long before = offsetPaging ? 0 : nextBefore;
            int offset = offsetPaging ? nextOffset : 0;
            if (!HasMore) return new SharedMediaPage(new(), before, offset);
            var request = new ListSharedMediaRequest { ChatId = ChatId, Sort = sort, SenderId = senderId, BeforeSeq = before, Offset = offset, Limit = 80 };
            request.Kinds.AddRange(filter);
            var response = await load(request, ct).ConfigureAwait(false);
            return new SharedMediaPage(response, before, offset);
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }
    public Task<bool> LoadMoreAsync(CancellationToken ct = default) => HasMore ? Load.ExecuteAsync(new(), ct) : Task.FromResult(false);

    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } page || ReferenceEquals(applied, page)) return;
        applied = page;
        foreach (var item in page.Response.Items)
        {
            var segment = item.Segment;
            var media = segment?.Image?.Media ?? segment?.Video?.Media ?? segment?.Record?.Media ?? segment?.File?.Media ?? segment?.MarketFace?.Media;
            string part = media is null ? Convert.ToBase64String(segment?.ToByteArray() ?? []) : "ord:" + media.Ord;
            var key = (item.Seq, item.Kind, part);
            if (positions.TryGetValue(key, out int index)) items[index] = item.Clone();
            else { positions[key] = items.Count; items.Add(item.Clone()); }
        }
        nextBefore = page.Response.NextBeforeSeq; nextOffset = page.Response.NextOffset;
        bool hasCursor = offsetPaging ? nextOffset != 0 : nextBefore != 0;
        bool advances = offsetPaging ? nextOffset > page.Offset : nextBefore > 0 && (page.BeforeSeq == 0 || nextBefore < page.BeforeSeq);
        HasMore = hasCursor && advances;
        PaginationError = hasCursor && !advances ? "服务端分页游标未推进，请重新加载媒体列表。" : null;
        Items = items.ToArray();
        PropertyChanged?.Invoke(this, new(null));
    }
    public void Dispose() { Load.PropertyChanged -= Loaded; Load.Dispose(); }
}
