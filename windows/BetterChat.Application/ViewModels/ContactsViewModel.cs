using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record ContactsLoadRequest(bool RefreshFromQq = false);
public sealed record FriendDeletion(long UserId);
public sealed record ContactDirectory(IReadOnlyList<Peer> Friends, IReadOnlyList<Peer> Groups,
    IReadOnlyList<FriendCategory> Categories, bool IsCached);

public sealed class ContactsViewModel : INotifyPropertyChanged, IDisposable, IAsyncDisposable
{
    private readonly IContactService api;
    private readonly IChatReadRepository repository;
    private readonly IContactDirectoryCache cache;
    private readonly IUiDispatcher dispatcher;
    private volatile bool disposed;
    private bool loaded;
    public ContactDirectory Directory { get; private set; } = new([], [], [], true);
    public long? ConfirmedDeletedUserId { get; private set; }
    public RpcOperationViewModel<ContactsLoadRequest, ContactDirectory> Load { get; }
    public RpcOperationViewModel<FriendDeletion, ContactDirectory> DeleteFriend { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public ContactsViewModel(IContactService api, IChatReadRepository repository, IUiDispatcher dispatcher, IContactDirectoryCache cache)
    {
        this.api = api; this.repository = repository; this.dispatcher = dispatcher; this.cache = cache;
        Load = new(LoadCoreAsync, dispatcher, mutation: false);
        Load.PropertyChanged += OperationChanged;
        DeleteFriend = new(async (request, ct) =>
        {
            await dispatcher.InvokeAsync(() =>
            {
                ct.ThrowIfCancellationRequested();
                if (disposed || ConfirmedDeletedUserId == request.UserId || !Directory.Friends.Any(p => p.PeerId == request.UserId))
                    throw new InvalidOperationException("请先加载联系人并选择要删除的好友。");
                Load.Cancel();
            }).ConfigureAwait(false);
            await api.DeleteFriendAsync(new() { UserId = request.UserId }, ct).ConfigureAwait(false);
            await dispatcher.InvokeAsync(() =>
            {
                if (disposed) return;
                ConfirmedDeletedUserId = request.UserId;
                PropertyChanged?.Invoke(this, new(nameof(ConfirmedDeletedUserId)));
            }).ConfigureAwait(false);
            // 服务器已确认删除后，即使页面随即取消，也要完成当前账号的本地缓存修正。
            var snapshot = await cache.RemoveFriendAsync(request.UserId, CancellationToken.None).ConfigureAwait(false);
            return Project(snapshot, true);
        }, dispatcher, true);
        DeleteFriend.PropertyChanged += FriendDeleted;
    }

    private void OperationChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || Load.State != OperationState.Succeeded || Load.Result is not { } result || ReferenceEquals(result, Directory)) return;
        Directory = result; loaded = true; ConfirmedDeletedUserId = null;
        PropertyChanged?.Invoke(this, new(nameof(ConfirmedDeletedUserId)));
        PropertyChanged?.Invoke(this, new(nameof(Directory)));
    }

    public Task<bool> LoadAsync(bool refreshFromQq = false, CancellationToken ct = default) =>
        Load.ExecuteAsync(new(refreshFromQq), ct);

    private void FriendDeleted(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || DeleteFriend.State != OperationState.Succeeded || DeleteFriend.Result is not { } result || ReferenceEquals(result, Directory)) return;
        Directory = result; loaded = true; PropertyChanged?.Invoke(this, new(nameof(Directory)));
    }

    private async Task<ContactDirectory> LoadCoreAsync(ContactsLoadRequest request, CancellationToken ct)
    {
        if (DeleteFriend.IsBusy) throw new InvalidOperationException("请等待好友删除操作结束后刷新。");
        if (!loaded)
        {
            var snapshot = await cache.ReadContactsAsync(ct).ConfigureAwait(false);
            var peers = snapshot is null ? await repository.GetPeersAsync(ct).ConfigureAwait(false) : [];
            await dispatcher.InvokeAsync(() =>
            {
                if (disposed || ct.IsCancellationRequested) return;
                Directory = snapshot is null
                    ? new(peers.Where(p => p.Kind == PeerKind.User && p.IsFriend).Select(p => p.Clone()).ToArray(),
                        peers.Where(p => p.Kind == PeerKind.Group).Select(p => p.Clone()).ToArray(), [], true)
                    : Project(snapshot, true);
                loaded = true;
                PropertyChanged?.Invoke(this, new(nameof(Directory)));
            }).ConfigureAwait(false);
        }
        ct.ThrowIfCancellationRequested();
        if (request.RefreshFromQq)
            await api.RefreshContactsAsync(new(), ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        long revision = await cache.GetContactsRevisionAsync(ct).ConfigureAwait(false);
        var friends = api.ListFriendsAsync(new(), ct);
        var groups = api.ListGroupsAsync(new(), ct);
        await Task.WhenAll(friends, groups).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        // 好友与群列表作为一份完整结果发布；特别关心与原分组的重复归属必须保留。
        var complete = new ContactLists(friends.Result, groups.Result);
        if (!await cache.TrySaveContactsAsync(complete, revision, ct).ConfigureAwait(false))
            throw new IOException("联系人缓存已更新，请重新加载列表。");
        ct.ThrowIfCancellationRequested();
        return Project(complete, false);
    }

    private static ContactDirectory Project(ContactLists snapshot, bool cached) => new(
        snapshot.Friends.Friends.Select(p => p.Clone()).ToArray(), snapshot.Groups.Groups.Select(p => p.Clone()).ToArray(),
        snapshot.Friends.Categories.Select(c => c.Clone()).ToArray(), cached);

    public void Dispose()
    {
        disposed = true; Load.PropertyChanged -= OperationChanged; DeleteFriend.PropertyChanged -= FriendDeleted;
        Load.Dispose(); DeleteFriend.Dispose();
    }
    public async ValueTask DisposeAsync()
    {
        Dispose();
        await Task.WhenAll(Load.WaitForIdleAsync(), DeleteFriend.WaitForIdleAsync()).ConfigureAwait(false);
    }
}
