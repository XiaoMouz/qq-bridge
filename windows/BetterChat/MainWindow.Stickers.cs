using BetterChat.Application.ViewModels;
using BetterChat.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    // 表情面板的「收藏」页：QQ 收藏表情的缩略图网格，点一下发送；没准备好的先准备再发。面板关闭时取消加载。
    private FrameworkElement StickerPanel(Flyout popup, long chat)
    {
        var page = new StackPanel { Spacing = 8 };
        if (runtime is not { } session) return page;
        var cancel = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var vm = new StickerCatalogViewModel(session.ListStickersAsync, session.PrepareStickersAsync, session.AddStickerAsync, new UiDispatcher(DispatcherQueue));
        popup.Closed += (_, _) => { cancel.Cancel(); cancel.Dispose(); vm.Dispose(); };
        var ct = cancel.Token;
        var status = new TextBlock { Text = "正在加载收藏表情…", Style = (Style)Microsoft.UI.Xaml.Application.Current.Resources["SecondaryCaptionTextBlockStyle"] };
        var refresh = new HyperlinkButton { Content = "从 QQ 刷新", Padding = new Thickness(4, 0, 4, 0) };
        var header = new Grid(); header.ColumnDefinitions.Add(new ColumnDefinition()); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(status); Grid.SetColumn(refresh, 1); header.Children.Add(refresh);
        var grid = new GridView { Height = 300, Width = 360, IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.None };
        page.Children.Add(header); page.Children.Add(grid);
        var thumbs = new SemaphoreSlim(4, 4);
        FrameworkElement Tile(Sticker item)
        {
            var image = new Image { Width = 72, Height = 72, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform };
            var tile = new Grid { Width = 80, Height = 80, Tag = item.Md5 };
            tile.Children.Add(new TextBlock { Text = item.Desc.Length > 0 ? item.Desc : "表情", Style = (Style)Microsoft.UI.Xaml.Application.Current.Resources["CaptionTextBlockStyle"], TextWrapping = TextWrapping.Wrap, MaxLines = 2, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.6 });
            tile.Children.Add(image);
            ToolTipService.SetToolTip(tile, item.Desc.Length > 0 ? item.Desc : "收藏表情");
            string sha = item.ThumbSha256.Length == 64 ? item.ThumbSha256 : item.Sha256;
            if (sha.Length == 64) tile.Loaded += async (_, _) =>
            {
                if (image.Source is not null) return;
                try
                {
                    await thumbs.WaitAsync(ct);
                    try { var uri = await PreviewUri(session.Api, sha, ct); if (!ct.IsCancellationRequested) image.Source = new BitmapImage(uri) { DecodePixelWidth = 144 }; }
                    finally { thumbs.Release(); }
                }
                catch (OperationCanceledException) { }
                catch (Exception) { /* 缩略图失败只显示文字，不影响发送。 */ }
            };
            return tile;
        }
        async Task Load(bool fromQq)
        {
            status.Text = fromQq ? "正在从 QQ 刷新…" : "正在加载收藏表情…";
            if (!await vm.LoadAsync(fromQq, ct)) { ct.ThrowIfCancellationRequested(); status.Text = vm.Load.Error ?? "加载失败，请重试。"; return; }
            ct.ThrowIfCancellationRequested();
            grid.ItemsSource = vm.Items.Select(Tile).ToList();
            status.Text = vm.Items.Count == 0 ? "还没有收藏表情；右键消息里的图片可以收藏。" : $"{vm.Items.Count} 个收藏表情";
        }
        bool sending = false;
        grid.ItemClick += async (_, e) => await Guard(async () =>
        {
            if (sending || e.ClickedItem is not FrameworkElement { Tag: string md5 } || runtime != session || selectedChat != chat) return;
            sending = true; status.Text = "正在发送…";
            try
            {
                var item = vm.Items.FirstOrDefault(s => s.Md5 == md5);
                if (item is null) return;
                if (item.Sha256.Length != 64 && !await vm.PrepareAsync([md5], ct)) { status.Text = vm.Prepare.Error ?? "表情准备失败，请重试。"; return; }
                ct.ThrowIfCancellationRequested();
                long reply = replySeq;
                await session.SendMessageAsync(vm.CreateMessage(md5, chat, RandomId(), reply), lifetime.Token);
                if (selectedChat == chat && replySeq == reply && reply != 0) { replySeq = 0; replies[chat] = 0; UpdateReply(); }
                popup.Hide();
            }
            finally { sending = false; }
        });
        refresh.Click += async (_, _) => await Guard(() => Load(true));
        _ = Guard(() => Load(false));
        return page;
    }
    private async Task AddMessageSticker(string sha, ClientSessionRuntime session)
    {
        if (runtime != session) return;
        using var vm = new StickerCatalogViewModel(session.ListStickersAsync, session.PrepareStickersAsync, session.AddStickerAsync, new UiDispatcher(DispatcherQueue));
        if (!await vm.AddAsync(sha, lifetime.Token)) throw new IOException(vm.Add.Error ?? "收藏结果待确认，请刷新收藏列表。");
        if (runtime == session) { Notice.Message = "已收藏表情。"; Notice.Severity = InfoBarSeverity.Success; Notice.IsOpen = true; }
    }
}
