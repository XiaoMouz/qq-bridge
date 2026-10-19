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

    private void AvatarLoaded(object sender, RoutedEventArgs args) => LoadVisibleAvatar((PersonPicture)sender);
    private void AvatarContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender.IsLoaded) LoadVisibleAvatar((PersonPicture)sender);
    }
    private void AvatarUnloaded(object sender, RoutedEventArgs args)
    {
        // 会话行重排时容器会被回收复用：新位置的 Loaded 可能先到、旧位置的 Unloaded 后到，
        // 这时元素仍在树上，清掉就把刚载入的头像抹成首字母（2026-10-19 录屏）。
        var picture = (PersonPicture)sender;
        if (!picture.IsLoaded) ResetAvatar(picture);
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
        var source = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        visibleAvatars[picture] = source;
        var ct = source.Token;
        var sessionApi = api;
        string hash = peer?.AvatarSha256 ?? "";
        string key = $"{group}:{id}:{hash}";
        // 已经载入过的头像直接同步设上，不经过 await，重排后的行不会先闪一下首字母。
        if (avatarImages.TryGetValue(key, out var cached) && cached.IsCompletedSuccessfully)
        {
            visibleAvatars.Remove(picture); source.Dispose(); picture.ProfilePicture = cached.Result; return;
        }
        try
        {
            // 行离开视口就取消排队，复用容器时不能把旧联系人的头像写到新行。
            await avatarRequests.WaitAsync(ct);
            BitmapImage? bitmap;
            try
            {
                if (!avatarImages.TryGetValue(key, out var task))
                {
                    if (avatarImages.Count >= 512) avatarImages.Clear();
                    task = FetchAvatar(sessionApi, id, group, hash, lifetime.Token);
                    avatarImages[key] = task;
                }
                bitmap = await task;
            }
            finally { avatarRequests.Release(); }
            ct.ThrowIfCancellationRequested();
            if (api == sessionApi && ReferenceEquals(picture.DataContext, row)) picture.ProfilePicture = bitmap;
        }
        catch (OperationCanceledException) { }
        catch (Exception)
        {
            if (api == sessionApi) avatarImages.Remove(key);
        }
    }
    private async Task<BitmapImage?> FetchAvatar(BetterChat.Core.BridgeApi sessionApi, long id, bool group, string hash, CancellationToken ct)
    {
        if (hash.Length == 0)
        {
            var request = new GetAvatarsRequest();
            if (group) request.GroupIds.Add(id); else request.UserIds.Add(id);
            var result = await SessionFor(sessionApi).GetAvatarsAsync(request, ct);
            hash = (group ? result.Groups : result.Avatars).FirstOrDefault(a => a.UserId == id)?.Sha256 ?? "";
        }
        if (hash.Length == 0) return null;
        var uri = await PreviewUri(sessionApi, hash, ct);
        ct.ThrowIfCancellationRequested();
        return new BitmapImage { DecodePixelWidth = 96, UriSource = uri };
    }
    private void ClearAvatars()
    {
        foreach (var source in visibleAvatars.Values) { source.Cancel(); source.Dispose(); }
        visibleAvatars.Clear(); avatarImages.Clear();
    }
}

