using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private readonly SemaphoreSlim avatarRequests = new(4, 4);
    private readonly Dictionary<string, Task<BitmapImage?>> avatarImages = [];
    private readonly Dictionary<PersonPicture, CancellationTokenSource> visibleAvatars = [];

    private readonly HashSet<PersonPicture> loadedAvatars = [];
    private void AvatarLoaded(object sender, RoutedEventArgs args)
    {
        var picture = (PersonPicture)sender;
        loadedAvatars.Add(picture); LoadVisibleAvatar(picture);
    }
    private void AvatarContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender.IsLoaded) LoadVisibleAvatar((PersonPicture)sender);
    }
    private void AvatarUnloaded(object sender, RoutedEventArgs args)
    {
        // 会话行重排时容器会被回收复用：新位置的 Loaded 可能先到、旧位置的 Unloaded 后到，
        // 这时元素仍在树上，清掉就把刚载入的头像抹成首字母（2026-10-19 录屏）。
        var picture = (PersonPicture)sender;
        if (!picture.IsLoaded) { loadedAvatars.Remove(picture); ResetAvatar(picture); }
    }
    private void ResetAvatar(PersonPicture picture)
    {
        if (visibleAvatars.Remove(picture, out var old)) { old.Cancel(); old.Dispose(); }
        picture.ProfilePicture = null;
    }
    private async void LoadVisibleAvatar(PersonPicture picture)
    {
        ResetAvatar(picture);
        if (api is null || picture.DataContext is not ListEntry row) return;
        // 搜索结果的消息行显示所在会话的头像。
        object value = row.Value is Message found && dialogIndex.GetValueOrDefault(found.ChatId) is { } foundIn ? foundIn : row.Value;
        var peer = value switch
        {
            Peer p => p,
            Dialog d => peerIndex.GetValueOrDefault((d.PeerId, d.Scene == Scene.Group)),
            _ => null
        };
        long id = peer?.PeerId ?? (value is Dialog dialog ? dialog.PeerId : 0);
        if (id == 0) return;
        bool group = peer?.Kind == PeerKind.Group || value is Dialog { Scene: Scene.Group };
        // 联系人页的行来自好友 / 群列表快照，头像变了不会跟着更新；同步来的资料（pts 推送）更新，优先用它的哈希。
        string hash = peerIndex.GetValueOrDefault((id, group))?.AvatarSha256 is { Length: > 0 } synced ? synced : peer?.AvatarSha256 ?? "";
        string key = AvatarKey(id, group, hash);
        // 已经载入过的头像直接同步设上，不经过 await，重排后的行不会先闪一下首字母。
        if (avatarImages.TryGetValue(key, out var cached) && cached.IsCompletedSuccessfully && cached.Result is { } ready)
        {
            picture.ProfilePicture = ready; return;
        }
        var source = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        visibleAvatars[picture] = source;
        var sessionApi = api;
        try
        {
            // 行离开视口只取消这一行的等待；下载本身继续，回到视口时直接用缓存。
            var bitmap = await AvatarImage(sessionApi, id, group, hash).WaitAsync(source.Token);
            if (api == sessionApi && ReferenceEquals(picture.DataContext, row)) picture.ProfilePicture = bitmap;
        }
        catch (OperationCanceledException) { }
        catch (Exception) { /* 失败保留姓名占位；AvatarImage 已移除失败的缓存，下次进入视口重试。 */ }
        finally
        {
            if (visibleAvatars.TryGetValue(picture, out var current) && current == source) visibleAvatars.Remove(picture);
            source.Dispose();
        }
    }
    private static string AvatarKey(long id, bool group, string hash) => $"{group}:{id}:{hash}";
    // 列表、气泡、资料页共用：同一个头像只下载一次。没有头像（服务端还没取到）和失败都不缓存，
    // 原来把空结果当成功缓存，服务端那一刻正好在别处下载同一个头像（avatarInFlight 直接返回空）时，这一行到重启前都是首字母。
    private Task<BitmapImage?> AvatarImage(BetterChat.Core.BridgeApi sessionApi, long id, bool group, string hash)
    {
        string key = AvatarKey(id, group, hash);
        if (avatarImages.TryGetValue(key, out var task)) return task;
        if (avatarImages.Count >= 512) avatarImages.Clear();
        task = FetchAvatar(sessionApi, id, group, hash, lifetime.Token);
        avatarImages[key] = task;
        _ = task.ContinueWith(t =>
        {
            if ((t.IsCompletedSuccessfully && t.Result is null || !t.IsCompletedSuccessfully) && avatarImages.TryGetValue(key, out var current) && current == t) avatarImages.Remove(key);
        }, TaskScheduler.FromCurrentSynchronizationContext());
        return task;
    }
    private async Task<BitmapImage?> FetchAvatar(BetterChat.Core.BridgeApi sessionApi, long id, bool group, string hash, CancellationToken ct)
    {
        if (hash.Length == 0) hash = await AvatarHash(sessionApi, id, group, ct);
        if (hash.Length == 0) return null;
        // 只限制下载并发；查哈希走批量请求，不能排在这四个名额里，否则一次只能攒到四个。
        await avatarRequests.WaitAsync(ct);
        Uri uri;
        try { uri = await PreviewUri(sessionApi, hash, ct); }
        finally { avatarRequests.Release(); }
        ct.ThrowIfCancellationRequested();
        return new BitmapImage { DecodePixelWidth = 96, UriSource = uri };
    }

    // 没带哈希的头像攒 150 毫秒一起问，一次最多 50 个（同 iOS AvatarLoader）。原来每行单独发一次 GetAvatars、
    // 最多 4 个并发，联系人页几百个好友要排很久；服务端对没下载过的头像是当场下载，单次就要 0.5–2.6 秒。
    private readonly Dictionary<(bool Group, long Id), TaskCompletionSource<string>> avatarHashes = [];
    private readonly List<(bool Group, long Id)> avatarHashQueue = [];
    private bool avatarHashFlushing;
    private Task<string> AvatarHash(BetterChat.Core.BridgeApi sessionApi, long id, bool group, CancellationToken ct)
    {
        if (avatarHashes.TryGetValue((group, id), out var waiting)) return waiting.Task;
        var result = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        avatarHashes[(group, id)] = result; avatarHashQueue.Add((group, id));
        if (!avatarHashFlushing) { avatarHashFlushing = true; _ = FlushAvatarHashes(sessionApi, ct); }
        return result.Task;
    }
    private async Task FlushAvatarHashes(BetterChat.Core.BridgeApi sessionApi, CancellationToken ct)
    {
        try
        {
            await Task.Delay(150, ct);
            while (avatarHashQueue.Count > 0 && api == sessionApi)
            {
                var batch = avatarHashQueue.Take(50).ToList();
                avatarHashQueue.RemoveRange(0, batch.Count);
                var request = new GetAvatarsRequest();
                request.UserIds.Add(batch.Where(k => !k.Group).Select(k => k.Id));
                request.GroupIds.Add(batch.Where(k => k.Group).Select(k => k.Id));
                Dictionary<(bool, long), string> found = [];
                try
                {
                    var response = await SessionFor(sessionApi).GetAvatarsAsync(request, ct);
                    foreach (var a in response.Avatars) found[(false, a.UserId)] = a.Sha256;
                    foreach (var a in response.Groups) found[(true, a.UserId)] = a.Sha256;
                }
                catch (Exception) when (!ct.IsCancellationRequested) { /* 这一批按「没有头像」返回，不缓存，下次进入视口再问。 */ }
                foreach (var key in batch)
                    if (avatarHashes.Remove(key, out var waiter)) waiter.TrySetResult(found.GetValueOrDefault(key) ?? "");
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            avatarHashFlushing = false;
            // 账号切换或取消：还在等的一律按没有头像收尾，不留悬挂的任务。
            if (api != sessionApi || ct.IsCancellationRequested)
            {
                foreach (var waiter in avatarHashes.Values) waiter.TrySetResult("");
                avatarHashes.Clear(); avatarHashQueue.Clear();
            }
        }
    }
    // 资料同步带来新的头像哈希后，补上还显示首字母的可见行；行是保留复用的，不会再触发 Loaded。
    // 资料索引在会话列表快照到达时整体替换，联系人目录变化记在 contactRevision；两者都没变就不用补。
    private (object? Peers, long Contacts) avatarSources;
    private void RefreshMissingAvatars()
    {
        (object? Peers, long Contacts) sources = (peerIndex, contactRevision);
        if (ReferenceEquals(sources.Peers, avatarSources.Peers) && sources.Contacts == avatarSources.Contacts) return;
        avatarSources = sources;
        foreach (var picture in loadedAvatars.Where(p => p.ProfilePicture is null && !visibleAvatars.ContainsKey(p)).ToList()) LoadVisibleAvatar(picture);
    }
    private void ClearAvatars()
    {
        foreach (var source in visibleAvatars.Values) { source.Cancel(); source.Dispose(); }
        visibleAvatars.Clear(); avatarImages.Clear(); loadedAvatars.Clear(); avatarSources = default;
        foreach (var waiter in avatarHashes.Values) waiter.TrySetResult("");
        avatarHashes.Clear(); avatarHashQueue.Clear();
    }
}

