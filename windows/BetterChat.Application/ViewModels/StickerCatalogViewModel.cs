using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record StickerListQuery(bool Refresh);
public sealed record StickerListResult(ListStickersResponse Response, long Revision);
public sealed record StickerPrepareQuery(IReadOnlyList<string> Md5);
public sealed record StickerPrepareResult(IReadOnlyList<Sticker> Ready, IReadOnlyList<string> Missing);
public sealed record StickerAddQuery(string Sha256);

public sealed class StickerCatalogViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly Dictionary<string, Sticker> prepared = new(StringComparer.OrdinalIgnoreCase);
    private List<Sticker> catalog = [];
    private long revision;
    private StickerListResult? appliedList;
    private StickerPrepareResult? appliedPrepare;
    private AddStickerResponse? appliedAdd;
    public IReadOnlyList<Sticker> Items { get; private set; } = [];
    public IReadOnlyList<string> Missing { get; private set; } = [];
    public bool NeedsRefresh { get; private set; }
    public RpcOperationViewModel<StickerListQuery, StickerListResult> Load { get; }
    public RpcOperationViewModel<StickerPrepareQuery, StickerPrepareResult> Prepare { get; }
    public RpcOperationViewModel<StickerAddQuery, AddStickerResponse> Add { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public StickerCatalogViewModel(IMediaService api, IUiDispatcher dispatcher)
        : this(api.ListStickersAsync, api.PrepareStickersAsync, api.AddStickerAsync, dispatcher) { }

    public StickerCatalogViewModel(
        Func<ListStickersRequest, CancellationToken, Task<ListStickersResponse>> list,
        Func<PrepareStickersRequest, CancellationToken, Task<PrepareStickersResponse>> prepare,
        Func<AddStickerRequest, CancellationToken, Task<AddStickerResponse>> add, IUiDispatcher dispatcher)
    {
        Load = new(async (query, ct) =>
        {
            long start = Interlocked.Read(ref revision);
            return new(await list(new() { Refresh = query.Refresh }, ct).ConfigureAwait(false), start);
        }, dispatcher, false);
        Prepare = new(async (query, ct) =>
        {
            var requested = query.Md5.Select(m => NormalizeHash(m, 32)).Distinct().ToArray();
            var ready = new Dictionary<string, Sticker>(StringComparer.OrdinalIgnoreCase);
            foreach (var batch in requested.Chunk(60))
            {
                ct.ThrowIfCancellationRequested();
                var request = new PrepareStickersRequest(); request.Md5.AddRange(batch);
                var response = await prepare(request, ct).ConfigureAwait(false);
                foreach (var sticker in response.Stickers)
                    if (batch.Contains(sticker.Md5, StringComparer.OrdinalIgnoreCase) && ValidHash(sticker.Sha256, 64))
                        ready[sticker.Md5] = sticker.Clone();
            }
            return new(ready.Values.ToArray(), requested.Where(m => !ready.ContainsKey(m)).ToArray());
        }, dispatcher, false);
        Add = new((query, ct) => add(new() { Sha256 = NormalizeHash(query.Sha256, 64) }, ct), dispatcher, true);
        Load.PropertyChanged += Loaded; Prepare.PropertyChanged += Prepared; Add.PropertyChanged += Added;
    }

    public Task<bool> LoadAsync(bool refresh = false, CancellationToken ct = default) => Load.ExecuteAsync(new(refresh), ct);
    public Task<bool> PrepareAsync(IEnumerable<string> md5, CancellationToken ct = default) => Prepare.ExecuteAsync(new(md5.ToArray()), ct);
    public Task<bool> AddAsync(string sha256, CancellationToken ct = default) => Add.ExecuteAsync(new(sha256), ct);
    public SendMessageRequest CreateMessage(string md5, long chatId, long randomId, long replyToSeq = 0)
    {
        if (chatId <= 0 || randomId <= 0 || randomId > MessageIdentity.MaxValue || replyToSeq < 0)
            throw new ArgumentException("贴纸发送目标或幂等 ID 无效。");
        var sticker = Items.FirstOrDefault(s => s.Md5.Equals(md5, StringComparison.OrdinalIgnoreCase));
        if (sticker is null || !ValidHash(sticker.Sha256, 64)) throw new InvalidOperationException("请先准备所选贴纸，再发送。");
        var request = new SendMessageRequest { ChatId = chatId, ClientRandomId = randomId, ReplyToSeq = replyToSeq };
        request.Segments.Add(new OutgoingSegment { Image = new OutgoingMedia { Sha256 = sticker.Sha256,
            Sticker = true, Summary = string.IsNullOrEmpty(sticker.Desc) ? "[动画表情]" : sticker.Desc } });
        return request;
    }

    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } result || ReferenceEquals(appliedList, result)) return;
        appliedList = result;
        catalog = result.Response.Stickers.GroupBy(s => s.Md5, StringComparer.OrdinalIgnoreCase).Select(g => g.First().Clone()).ToList();
        NeedsRefresh = result.Revision != Interlocked.Read(ref revision);
        Publish();
    }
    private void Prepared(object? sender, PropertyChangedEventArgs args)
    {
        if (Prepare.State != OperationState.Succeeded || Prepare.Result is not { } result || ReferenceEquals(appliedPrepare, result)) return;
        appliedPrepare = result;
        foreach (var sticker in result.Ready) prepared[sticker.Md5] = sticker.Clone();
        Missing = result.Missing;
        Publish();
    }
    private void Added(object? sender, PropertyChangedEventArgs args)
    {
        if (Add.State != OperationState.Succeeded || Add.Result is not { } result || ReferenceEquals(appliedAdd, result)) return;
        appliedAdd = result; Interlocked.Increment(ref revision); NeedsRefresh = true;
        PropertyChanged?.Invoke(this, new(nameof(NeedsRefresh)));
    }
    private void Publish()
    {
        // 列表的描述和商城标记以列表为准；准备结果只补齐媒体哈希，不让迟到列表撤销已准备状态。
        Items = catalog.Select(sticker =>
        {
            var item = sticker.Clone();
            if (prepared.TryGetValue(item.Md5, out var ready))
            {
                if (item.Sha256.Length == 0) item.Sha256 = ready.Sha256;
                if (item.ThumbSha256.Length == 0) item.ThumbSha256 = ready.ThumbSha256;
            }
            return item;
        }).ToArray();
        PropertyChanged?.Invoke(this, new(null));
    }
    private static bool ValidHash(string value, int length) => value.Length == length && value.All(Uri.IsHexDigit);
    private static string NormalizeHash(string value, int length) => ValidHash(value, length)
        ? value.ToLowerInvariant() : throw new ArgumentException("媒体哈希格式不正确。");
    public void Dispose()
    {
        Load.PropertyChanged -= Loaded; Prepare.PropertyChanged -= Prepared; Add.PropertyChanged -= Added;
        Load.Dispose(); Prepare.Dispose(); Add.Dispose();
    }
}
