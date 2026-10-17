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
        var picture = (PersonPicture)sender;
        if (visibleAvatars.Remove(picture, out var old)) { old.Cancel(); old.Dispose(); }
        picture.ProfilePicture = null;
    }
    private async void LoadVisibleAvatar(PersonPicture picture)
    {
        AvatarUnloaded(picture, new RoutedEventArgs());
        if (api is null || picture.DataContext is not ListEntry row) return;
        var peer = row.Value switch
        {
            Peer p => p,
            Dialog d => peerIndex.GetValueOrDefault((d.PeerId, d.Scene == Scene.Group)),
            _ => null
        };
        long id = peer?.PeerId ?? (row.Value is Dialog dialog ? dialog.PeerId : 0);
        if (id == 0) return;
        bool group = peer?.Kind == PeerKind.Group || row.Value is Dialog { Scene: Scene.Group };
        var source = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        visibleAvatars[picture] = source;
        var ct = source.Token;
        var sessionApi = api;
        string hash = peer?.AvatarSha256 ?? "";
        string key = $"{group}:{id}:{hash}";
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

