using Microsoft.UI.Xaml;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    // 群成员一行：头像、群名片、昵称和 QQ 号，右边群主 / 管理员标签；点开成员资料。
    private FrameworkElement MemberRow(long userId, string name, string nickname, string role, Func<Task> open)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var avatar = new PersonPicture { Width = 32, Height = 32, DisplayName = name, Tag = userId };
        avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, userId);
        grid.Children.Add(avatar);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Text = (nickname.Length > 0 ? nickname + " · " : "") + userId, Style = Res<Style>("SecondaryCaptionTextBlockStyle") });
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        if (role is "owner" or "admin")
        {
            var badge = new Border
            {
                CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 1, 6, 1), VerticalAlignment = VerticalAlignment.Center,
                Background = Brush(role == "owner" ? "SystemFillColorCautionBackgroundBrush" : "SystemFillColorAttentionBackgroundBrush"),
                Child = new TextBlock { Text = role == "owner" ? "群主" : "管理员", Style = Res<Style>("CaptionTextBlockStyle") }
            };
            Grid.SetColumn(badge, 2); grid.Children.Add(badge);
        }
        var button = new Button { Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(12, 8, 12, 8), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        button.Click += async (_, _) => { button.IsEnabled = false; try { await Guard(open); } finally { button.IsEnabled = true; } };
        return button;
    }

    private async Task GroupMembers(Peer group, CancellationToken ct)
    {
        if (runtime is not { } session) return;
        long groupId = group.PeerId;
        var vm = new GroupMembersViewModel(groupId, session.ListGroupMembersAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        var count = Text("正在加载群成员…", 12); Details.Children.Add(count);
        var rows = new StackPanel { Spacing = 2 }; Details.Children.Add(rows);
        bool busy = false;
        var seen = new HashSet<long>();
        var more = new Button { Content = "加载更多成员" }; Details.Children.Add(more);
        async Task Load()
        {
            if (busy) return; busy = true; more.IsEnabled = false;
            try
            {
                if (!await vm.LoadMoreAsync(ct))
                {
                    ct.ThrowIfCancellationRequested();
                    if (featurePage != vm || runtime != session || !vm.HasMore) return;
                    throw new IOException(vm.Load.Error ?? "群成员加载失败。");
                }
                ct.ThrowIfCancellationRequested();
                if (featurePage != vm || runtime != session) return;
                foreach (var member in vm.Members)
                {
                    if (!seen.Add(member.UserId)) continue;
                    string name = member.Card.Length > 0 ? member.Card : member.Nickname;
                    rows.Children.Add(MemberRow(member.UserId, name.Length > 0 ? name : member.UserId.ToString(), member.Nickname != name ? member.Nickname : "", member.Role, async () =>
                    {
                        var profile = await session.GetUserProfileAsync(new() { UserId = member.UserId }, ct);
                        ct.ThrowIfCancellationRequested();
                        if (featurePage != vm || runtime != session) return;
                        if (profile.Profile?.Peer is not { } peer || peer.PeerId != member.UserId || peer.Kind != PeerKind.User) throw new IOException("成员资料返回的身份不匹配。");
                        await Go(ProfileKey(peer, groupId), () => { NewPage(); ShowProfile(peer, groupId); });
                    }));
                }
                count.Text = $"已加载 {seen.Count:N0} / {vm.Total:N0} 位成员" + (vm.Stale ? " · 缓存资料" : "");
                more.Visibility = vm.HasMore ? Visibility.Visible : Visibility.Collapsed;
                if (vm.Members.Count == 0) count.Text = "暂无成员资料";
            }
            finally { busy = false; more.IsEnabled = true; }
        }
        more.Click += async (_, _) => await Guard(Load);
        await Load();
    }

    private async Task OpenGroupAlbum(Peer group, GroupAlbum album)
    {
        var session = runtime; if (session is null) return;
        var ct = NewPage(); Detail(album.Name, DisplayName(group));
        var vm = new AlbumMediaViewModel(group.PeerId, album.Id, session.ListGroupAlbumMediaAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        if (album.Desc.Length > 0) Details.Children.Add(Text(album.Desc));
        var pictures = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = false };
        Details.Children.Add(pictures);
        var status = Text("", 12); Details.Children.Add(status);
        var more = new Button { Content = "加载更多照片" }; Details.Children.Add(more);
        var rendered = new Dictionary<string, (int Position, GroupAlbumMedia Snapshot)>();
        bool busy = false;
        async Task Load()
        {
            if (busy) return; busy = true; more.IsEnabled = false;
            try
            {
                if (!await vm.LoadMoreAsync(ct))
                { ct.ThrowIfCancellationRequested(); if (featurePage != vm || runtime != session) return; status.Text = vm.Load.Error ?? "加载失败，请重试。"; more.Content = "重试加载"; return; }
                ct.ThrowIfCancellationRequested();
                if (featurePage != vm || runtime != session) return;
                foreach (var media in vm.Items)
                {
                    bool existing = rendered.TryGetValue(media.Id, out var old);
                    if (existing && old.Snapshot.Equals(media)) continue;
                    var content = new StackPanel { Spacing = 6, Width = 180 };
                    if (Uri.TryCreate(media.ThumbUrl, UriKind.Absolute, out var thumb) && thumb.Scheme == "https")
                        content.Children.Add(new Image { Source = new BitmapImage(thumb), Width = 180, Height = 135, Stretch = Stretch.UniformToFill });
                    content.Children.Add(Text((media.IsVideo ? "视频 · " : "") + media.UploaderName, 12));
                    var button = ActionButton("查看", () => OpenAlbumMedia(media, ct)); button.Content = content;
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, media.IsVideo ? "播放相册视频" : "查看相册原图");
                    if (existing) pictures.Items[old.Position] = button;
                    else pictures.Items.Add(button);
                    rendered[media.Id] = (existing ? old.Position : pictures.Items.Count - 1, media.Clone());
                }
                more.Visibility = vm.HasMore ? Visibility.Visible : Visibility.Collapsed;
                more.Content = "加载更多照片";
                status.Text = vm.PaginationError ?? (vm.Items.Count > 0 ? $"已加载 {vm.Items.Count:N0} 项" : "相册中暂无内容");
            }
            finally { busy = false; more.IsEnabled = true; }
        }
        more.Click += async (_, _) => await Guard(Load);
        await Load();
    }

    private async Task OpenAlbumMedia(GroupAlbumMedia media, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (api is null) return;
        var uri = api.Transport.ResolveMedia(media.IsVideo ? media.VideoUrl : media.Url);
        if (!media.IsVideo)
        {
            await DialogBox("相册原图", new Image { Source = new BitmapImage(uri), MaxWidth = 800, MaxHeight = 600, Stretch = Stretch.Uniform });
            return;
        }
        var player = new MediaPlayerElement { Source = Windows.Media.Core.MediaSource.CreateFromUri(uri), AreTransportControlsEnabled = true, AutoPlay = false, Height = 450, MaxWidth = 800 };
        try { await DialogBox("相册视频", player); }
        finally { player.MediaPlayer?.Pause(); player.Source = null; }
    }
}
