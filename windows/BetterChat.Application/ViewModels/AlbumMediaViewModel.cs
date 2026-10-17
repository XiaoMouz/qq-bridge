using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record AlbumPageQuery;
public sealed record AlbumPage(string Cursor, ListGroupAlbumMediaResponse Response);

public sealed class AlbumMediaViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly List<GroupAlbumMedia> items = [];
    private readonly Dictionary<string, int> positions = [];
    private readonly HashSet<string> cursors = [];
    private string next = "";
    private AlbumPage? applied;
    public IReadOnlyList<GroupAlbumMedia> Items { get; private set; } = [];
    public bool HasMore { get; private set; } = true;
    public string? PaginationError { get; private set; }
    public string AlbumName { get; private set; } = "";
    public RpcOperationViewModel<AlbumPageQuery, AlbumPage> Load { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public AlbumMediaViewModel(long groupId, string albumId, IContactService api, IUiDispatcher dispatcher)
        : this(groupId, albumId, api.ListGroupAlbumMediaAsync, dispatcher) { }

    public AlbumMediaViewModel(long groupId, string albumId,
        Func<ListGroupAlbumMediaRequest, CancellationToken, Task<ListGroupAlbumMediaResponse>> load, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(groupId);
        ArgumentException.ThrowIfNullOrWhiteSpace(albumId);
        Load = new(async (_, ct) =>
        {
            string cursor = next;
            var response = await load(new() { GroupId = groupId, AlbumId = albumId, Cursor = cursor }, ct).ConfigureAwait(false);
            if (response.Media.Any(m => string.IsNullOrWhiteSpace(m.Id))) throw new IOException("相册返回缺少标识的媒体，请重试。");
            return new AlbumPage(cursor, response);
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }
    public Task<bool> LoadMoreAsync(CancellationToken ct = default) => HasMore ? Load.ExecuteAsync(new(), ct) : Task.FromResult(false);
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } page || ReferenceEquals(page, applied)) return;
        applied = page;
        foreach (var item in page.Response.Media)
        {
            if (positions.TryGetValue(item.Id, out int position)) items[position] = item.Clone();
            else { positions[item.Id] = items.Count; items.Add(item.Clone()); }
        }
        if (page.Response.AlbumName.Length > 0) AlbumName = page.Response.AlbumName;
        next = page.Response.NextCursor;
        bool advances = next.Length > 0 && next != page.Cursor && cursors.Add(next);
        HasMore = page.Response.HasMore && advances;
        PaginationError = page.Response.HasMore && !advances ? "相册分页游标没有推进或出现循环，请重新打开相册。" : null;
        Items = items.ToArray(); PropertyChanged?.Invoke(this, new(null));
    }
    public void Dispose() { Load.PropertyChanged -= Loaded; Load.Dispose(); }
}
