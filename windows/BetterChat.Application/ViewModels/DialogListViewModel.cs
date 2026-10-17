using System.Collections.ObjectModel;
using System.ComponentModel;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record DialogListQuery;
public sealed record DialogListSnapshot(IReadOnlyList<Dialog> Dialogs, IReadOnlyDictionary<long, Peer?> Peers,
    IReadOnlyDictionary<(long PeerId, bool Group), Peer> DisplayPeers);

// 和 iOS DialogItem.badgeCount、服务端推送角标同一规则：会提醒的会话算全部未读；
// 免打扰、群助手、只提醒 @我 的会话只算 @我 和回复我；@全体成员 不单独算。
public static class DialogBadge
{
    public static int Count(Dialog dialog) => dialog.NotifyPolicy is "muted" or "archived" or "mentions"
        ? (int)(dialog.UnreadMentions + dialog.UnreadReplies) : (int)dialog.UnreadCount;
}

public sealed class DialogRowViewModel(Dialog initial, Peer? peer = null) : INotifyPropertyChanged
{
    private Dialog value = initial.Clone();
    public long ChatId => value.ChatId;
    public int BadgeCount => DialogBadge.Count(value);
    public Dialog Snapshot => value.Clone();
    public string Title { get; private set; } = Name(initial, peer);
    public string AvatarSha256 { get; private set; } = peer?.AvatarSha256 ?? "";
    private static string Name(Dialog dialog, Peer? peer) =>
        !string.IsNullOrWhiteSpace(peer?.Remark) ? peer.Remark :
        !string.IsNullOrWhiteSpace(peer?.Name) ? peer.Name : dialog.PeerId.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public event PropertyChangedEventHandler? PropertyChanged;
    internal void Update(Dialog next, Peer? peer)
    {
        if (!value.Equals(next))
        {
            value = next.Clone();
            PropertyChanged?.Invoke(this, new(nameof(Snapshot)));
        }
        var title = Name(next, peer);
        if (Title != title) { Title = title; PropertyChanged?.Invoke(this, new(nameof(Title))); }
        var avatar = peer?.AvatarSha256 ?? "";
        if (AvatarSha256 != avatar) { AvatarSha256 = avatar; PropertyChanged?.Invoke(this, new(nameof(AvatarSha256))); }
    }
}

// 列表对象与行身份稳定，普通同步刷新不清空集合；选择按 chatId 保留，不依赖位置。
public sealed class DialogListViewModel : INotifyPropertyChanged, IDisposable, IAsyncDisposable
{
    private readonly ObservableCollection<DialogRowViewModel> rows = [];
    private readonly IUiDispatcher dispatcher;
    private DialogListSnapshot? applied;
    private volatile bool disposed;
    private long peerRevision = -1;
    private Dictionary<(long Account, PeerKind Kind, long Id), Peer> cachedPeers = [];
    public ReadOnlyObservableCollection<DialogRowViewModel> Items { get; }
    public long? SelectedChatId { get; private set; }
    public RpcOperationViewModel<DialogListQuery, DialogListSnapshot> Load { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public DialogListViewModel(IChatReadRepository repository, IUiDispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        Items = new(rows);
        Load = new(async (_, ct) =>
        {
            var directory = await repository.GetDialogDirectoryAsync(ct, peerRevision).ConfigureAwait(false);
            var dialogs = directory.Dialogs;
            // 排序和克隆留在后台读取之后；结果不持有仓储可变对象。
            var ordered = dialogs.OrderByDescending(d => d.Pinned)
                .ThenByDescending(d => d.Pinned ? d.PinnedAt : d.TopTime)
                .ThenBy(d => d.ChatId).Select(d => d.Clone()).ToArray();
            if (ordered.Any(d => d.ChatId <= 0) || ordered.Select(d => d.ChatId).Distinct().Count() != ordered.Length)
                throw new IOException("会话列表包含无效或重复 ID。");
            if (directory.Peers is { } changedPeers)
            {
                cachedPeers = changedPeers.ToDictionary(p => (p.QqAccountId, p.Kind, p.PeerId), p => p.Clone());
                peerRevision = directory.PeerRevision;
            }
            // 同号可能同时是群号、用户号，也可能属于多个 QQ 账号，必须使用完整协议键。
            var matched = ordered.ToDictionary(d => d.ChatId, d =>
            {
                PeerKind kind = d.Scene switch { Scene.Group => PeerKind.Group, Scene.Friend or Scene.Temp => PeerKind.User, _ => PeerKind.Unspecified };
                return cachedPeers.GetValueOrDefault((d.QqAccountId, kind, d.PeerId))?.Clone();
            });
            var displayPeers = cachedPeers.Values.GroupBy(p => (p.PeerId, p.Kind == PeerKind.Group))
                .ToDictionary(g => g.Key, g => g.First().Clone());
            return new DialogListSnapshot(ordered, matched, displayPeers);
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }
    public Task<bool> LoadAsync(CancellationToken ct = default) => Load.ExecuteAsync(new(), ct);
    public Task SelectAsync(long? chatId) => dispatcher.InvokeAsync(() =>
    {
        if (disposed) return;
        if (chatId.HasValue && !rows.Any(r => r.ChatId == chatId)) throw new ArgumentOutOfRangeException(nameof(chatId));
        SetSelection(chatId);
    });
    private void SetSelection(long? chatId)
    {
        if (SelectedChatId == chatId) return;
        SelectedChatId = chatId;
        PropertyChanged?.Invoke(this, new(nameof(SelectedChatId)));
    }
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || Load.State != OperationState.Succeeded || Load.Result is not { } result || ReferenceEquals(applied, result)) return;
        applied = result;
        var wanted = result.Dialogs.Select(d => d.ChatId).ToHashSet();
        for (int i = rows.Count - 1; i >= 0; i--) if (!wanted.Contains(rows[i].ChatId)) rows.RemoveAt(i);
        var existing = rows.ToDictionary(r => r.ChatId);
        for (int i = 0; i < result.Dialogs.Count; i++)
        {
            var dialog = result.Dialogs[i];
            if (existing.TryGetValue(dialog.ChatId, out var row))
            {
                // 普通新消息多数不改变顺序，避免为每行都从头扫描 ObservableCollection。
                if (!ReferenceEquals(rows[i], row)) rows.Move(rows.IndexOf(row), i);
                row.Update(dialog, result.Peers[dialog.ChatId]);
            }
            else rows.Insert(i, new(dialog, result.Peers[dialog.ChatId]));
        }
        if (SelectedChatId is { } selected && !wanted.Contains(selected)) SetSelection(null);
    }
    public void Dispose() { disposed = true; Load.PropertyChanged -= Loaded; Load.Dispose(); }
    public async ValueTask DisposeAsync() { Dispose(); await Load.WaitForIdleAsync().ConfigureAwait(false); }
}
