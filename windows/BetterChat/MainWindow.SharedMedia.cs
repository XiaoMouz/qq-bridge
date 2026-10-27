using BetterChat.Application.ViewModels;
using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    // 共享媒体的缩略图格子：方形裁切，视频叠播放图标，点开看图浮层；定位原消息放在右键菜单里，不在每格下面占一行。
    private FrameworkElement MediaTile(Message message, MediaInfo media, bool video, Func<Task> locate, CancellationToken ct)
    {
        var image = new Image { Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill };
        var frame = new Grid { Width = 140, Height = 140, CornerRadius = new CornerRadius(6), Background = Brush("SubtleFillColorSecondaryBrush") };
        // 视频本身叠了播放按钮，没缩略图时不再垫一个图标，免得两个图标叠在一起。
        if (!video) frame.Children.Add(new FontIcon { Glyph = "\uEB9F", FontSize = 24, Opacity = 0.4 });
        frame.Children.Add(image);
        if (video) frame.Children.Add(new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(0x99, 0, 0, 0)),
            Child = new FontIcon { Glyph = "\uE768", FontSize = 14, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White) } });
        var open = new Button { Content = frame, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, video ? "打开视频" : "打开图片");
        open.Click += async (_, _) => await Guard(() => OpenViewer(message, media));
        string hash = MediaPresentation.PreviewHash(media);
        if (hash.Length > 0 && runtime is { } session)
            open.Loaded += async (_, _) =>
            {
                if (image.Source is not null) return;
                try { var uri = await PreviewUri(session.Api, hash, ct); if (!ct.IsCancellationRequested) image.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(uri) { DecodePixelWidth = 280 }; }
                catch (OperationCanceledException) { }
                catch (Exception) { /* 缩略图失败只显示占位图标，点开仍可看原图。 */ }
            };
        ToolTipService.SetToolTip(open, $"{PeerName(message.SenderId, Scene.Friend)} · {DateTimeOffset.FromUnixTimeSeconds(message.Time).ToLocalTime():g}");
        var menu = new MenuFlyout();
        var view = new MenuFlyoutItem { Text = video ? "播放" : "查看", Icon = new FontIcon { Glyph = "\uE8A7" } };
        view.Click += async (_, _) => await Guard(() => OpenViewer(message, media));
        var jump = new MenuFlyoutItem { Text = "定位原消息", Icon = new FontIcon { Glyph = "\uE8BD" } };
        jump.Click += async (_, _) => await Guard(locate);
        menu.Items.Add(view); menu.Items.Add(jump); open.ContextFlyout = menu;
        return open;
    }

    private async Task ShowSharedMedia(long chat)
    {
        var session = runtime;
        if (session is null) return;
        await SaveDraft();
        if (runtime != session) return;
        var ct = NewPage();
        Detail("共享媒体");
        var kinds = new ComboBox { Header = "类型", SelectedIndex = 0, MinWidth = 110 };
        foreach (var label in new[] { "全部", "图片", "视频", "语音", "文件", "表情" }) kinds.Items.Add(label);
        kinds.SelectedIndex = 0;
        var order = new ComboBox { Header = "排序", SelectedIndex = 0, MinWidth = 110 };
        foreach (var label in new[] { "最新", "最早", "大小", "发送者" }) order.Items.Add(label);
        order.SelectedIndex = 0;
        var sender = new TextBox { Header = "发送者 QQ", PlaceholderText = "所有人", Width = 160 };
        var status = new TextBlock { Style = Res<Style>("SecondaryCaptionTextBlockStyle"), Visibility = Visibility.Collapsed };
        var loading = new ProgressRing { IsActive = false, Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
        // 图片、视频、表情用缩略图网格（点开进看图浮层），语音和文件用行。
        var grid = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = false };
        var files = new StackPanel { Spacing = 2 };
        var content = new StackPanel { Spacing = 8 }; content.Children.Add(grid); content.Children.Add(files);
        SharedMediaViewModel? vm = null;
        Button? more = null;
        void Render()
        {
            if (vm is null || ct.IsCancellationRequested || runtime != session) return;
            var tiles = new List<FrameworkElement>(); files.Children.Clear();
            foreach (var item in vm.Items)
            {
                var media = item.Segment?.Image?.Media ?? item.Segment?.Video?.Media ?? item.Segment?.Record?.Media
                    ?? item.Segment?.File?.Media ?? item.Segment?.MarketFace?.Media;
                var message = new Message { ChatId = chat, Seq = item.Seq, SenderId = item.SenderId, Time = item.Time };
                if (item.Segment is not null) message.Segments.Add(item.Segment);
                Task Locate() { ct.ThrowIfCancellationRequested(); return runtime == session ? Go(ChatKey(chat), () => OpenChat(chat, item.Seq)) : Task.CompletedTask; }
                bool visual = item.Segment is { } s && (s.Image is not null || s.Video is not null || s.MarketFace is not null);
                if (visual && media is not null) tiles.Add(MediaTile(message, media, item.Segment!.Video is not null, Locate, ct));
                else
                {
                    string name = item.Segment?.File?.Name is { Length: > 0 } fileName ? fileName : item.Segment?.Record is not null ? "语音" : item.Kind.ToString();
                    string detail = $"{Bytes(item.Size)} · {PeerName(item.SenderId, Scene.Friend)} · {DateTimeOffset.FromUnixTimeSeconds(item.Time).ToLocalTime():g}";
                    var row = FileRow(item.Segment?.Record is not null ? "\uE720" : FileGlyph(name), name, detail,
                        media is not null ? () => ShowMedia(message, media, name) : Locate);
                    var menu = new MenuFlyout(); var locate = new MenuFlyoutItem { Text = "定位原消息", Icon = new FontIcon { Glyph = "\uE8BD" } };
                    locate.Click += async (_, _) => await Guard(Locate); menu.Items.Add(locate); row.ContextFlyout = menu;
                    files.Children.Add(row);
                }
            }
            grid.ItemsSource = tiles;
            grid.Visibility = tiles.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            // 只在出错时写一行；加载了多少、是否到底由列表本身和「加载更多」按钮的可用状态表达。
            status.Text = vm.Load.State == OperationState.Failed ? "加载失败：" + vm.Load.Error : vm.PaginationError ?? "";
            status.Visibility = status.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            loading.IsActive = false; loading.Visibility = Visibility.Collapsed;
            // 到底了就不显示「加载更多」，不再写「已到末尾」。
            more!.IsEnabled = !vm.Load.IsBusy;
            more.Visibility = vm.HasMore ? Visibility.Visible : Visibility.Collapsed;
        }
        async Task LoadMore()
        {
            var current = vm;
            if (current is null) return;
            more!.IsEnabled = false;
            status.Visibility = Visibility.Collapsed; loading.IsActive = true; loading.Visibility = Visibility.Visible;
            await current.LoadMoreAsync(ct);
            ct.ThrowIfCancellationRequested();
            if (vm == current && runtime == session) Render();
        }
        async Task ApplyFilter()
        {
            long senderId = 0;
            if (!string.IsNullOrWhiteSpace(sender.Text) && (!long.TryParse(sender.Text, out senderId) || senderId <= 0))
                throw new ArgumentException("请输入有效的发送者 QQ 号码。");
            ct.ThrowIfCancellationRequested();
            if (runtime != session) return;
            vm?.Dispose();
            MediaKind[] filter = kinds.SelectedIndex > 0 ? [(MediaKind)kinds.SelectedIndex] : [];
            vm = new SharedMediaViewModel(chat, filter, (SharedMediaOrder)Math.Max(0, order.SelectedIndex), senderId,
                session.ListSharedMediaAsync, new UiDispatcher(DispatcherQueue));
            featurePage = vm;
            grid.ItemsSource = null; files.Children.Clear();
            await LoadMore();
        }
        more = ActionButton("加载更多", LoadMore);
        // 筛选条件一改就重新查，不需要单独的「筛选」按钮；发送者在回车或离开输入框时生效。
        kinds.SelectionChanged += async (_, _) => { if (vm is not null) await Guard(ApplyFilter); };
        order.SelectionChanged += async (_, _) => { if (vm is not null) await Guard(ApplyFilter); };
        string appliedSender = "";
        async Task SenderChanged() { if (vm is null || sender.Text.Trim() == appliedSender) return; appliedSender = sender.Text.Trim(); await ApplyFilter(); }
        sender.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await Guard(SenderChanged); } };
        sender.LostFocus += async (_, _) => await Guard(SenderChanged);
        var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        filters.Children.Add(kinds); filters.Children.Add(order); filters.Children.Add(sender);
        Details.Children.Add(filters);
        Details.Children.Add(status); Details.Children.Add(content); Details.Children.Add(loading); Details.Children.Add(more);
        await ApplyFilter();
    }
}
