using System.ComponentModel;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed class StorageItemsViewModel : IDisposable, IAsyncDisposable
{
    private readonly List<StorageItem> items = [];
    private readonly HashSet<string> seen = [];
    private uint offset;
    private ListStorageItemsResponse? applied;
    public IReadOnlyList<StorageItem> Items => items;
    public bool HasMore { get; private set; } = true;
    public RpcOperationViewModel<object, ListStorageItemsResponse> Load { get; }

    public StorageItemsViewModel(long chat, string category,
        Func<ListStorageItemsRequest, CancellationToken, Task<ListStorageItemsResponse>> load, IUiDispatcher dispatcher)
    {
        if (chat is <= 0 or > 9007199254740991) throw new ArgumentOutOfRangeException(nameof(chat));
        ArgumentException.ThrowIfNullOrWhiteSpace(category);
        Load = new(async (_, ct) =>
        {
            var request = new ListStorageItemsRequest { ChatId = chat, Offset = offset, Limit = 50 };
            request.Categories.Add(category);
            var response = await load(request, ct).ConfigureAwait(false);
            if (response.Items.Any(i => i.Sha256.Length != 64 || i.Sha256.Any(c => !char.IsAsciiHexDigit(c))))
                throw new IOException("存储列表包含无效的媒体标识。");
            _ = checked(offset + (uint)response.Items.Count);
            return response.Clone();
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }
    public Task<bool> LoadMoreAsync(CancellationToken ct = default) => HasMore ? Load.ExecuteAsync(new(), ct) : Task.FromResult(false);
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } page || ReferenceEquals(applied, page)) return;
        applied = page;
        // 偏移按服务器返回数推进，不能用去重后的数量，否则跨页重叠会反复读取旧位置。
        offset += (uint)page.Items.Count;
        foreach (var item in page.Items) if (seen.Add(item.Sha256)) items.Add(item.Clone());
        HasMore = page.More && page.Items.Count > 0;
    }
    public void Dispose() { Load.PropertyChanged -= Loaded; Load.Dispose(); }
    public async ValueTask DisposeAsync() { Dispose(); await Load.WaitForIdleAsync().ConfigureAwait(false); }
}
