using BetterChat.Application.ViewModels;
using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    // 共享媒体的缩略图格子：方形裁切，视频叠播放图标，点开看图浮层，下面一个「定位」。
    private FrameworkElement MediaTile(Message message, MediaInfo media, bool video, Func<Task> locate, CancellationToken ct)
    {
        var image = new Image { Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill };
        var frame = new Grid { Width = 140, Height = 140, CornerRadius = new CornerRadius(6), Background = Brush("SubtleFillColorSecondaryBrush") };
        frame.Children.Add(new FontIcon { Glyph = video ? "\uE714" : "\uEB9F", FontSize = 24, Opacity = 0.4 });
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
        var link = new HyperlinkButton { Content = "定位", Padding = new Thickness(0), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
        link.Click += async (_, _) => await Guard(locate);
        var panel = new StackPanel { Spacing = 2 }; panel.Children.Add(open); panel.Children.Add(link);
        return panel;
    }

    private async Task ShowSharedMedia(long chat)
    {
        var session = runtime;
        if (session is null) return;
        await SaveDraft();
        if (runtime != session) return;
        var ct = NewPage();
        Detail("共享媒体", "按类型、发送者与排序查找，打开原消息或媒体");
        var kinds = new ComboBox { Header = "类型", SelectedIndex = 0, MinWidth = 110 };
        foreach (var label in new[] { "全部", "图片", "视频", "语音", "文件", "表情" }) kinds.Items.Add(label);
        kinds.SelectedIndex = 0;
        var order = new ComboBox { Header = "排序", SelectedIndex = 0, MinWidth = 110 };
        foreach (var label in new[] { "最新", "最早", "大小", "发送者" }) order.Items.Add(label);
        order.SelectedIndex = 0;
        var sender = new TextBox { Header = "发送者 QQ", PlaceholderText = "全部", Width = 160 };
        var status = new TextBlock { Style = Res<Style>("SecondaryCaptionTextBlockStyle") };
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
                    var menu = new MenuFlyout(); var locate = new MenuFlyoutItem { Text = "定位原消息", Icon = new FontIcon { Glyph = "\uE8A7" } };
                    locate.Click += async (_, _) => await Guard(Locate); menu.Items.Add(locate); row.ContextFlyout = menu;
                    files.Children.Add(row);
                }
            }
            grid.ItemsSource = tiles;
            grid.Visibility = tiles.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            status.Text = vm.Load.State == OperationState.Failed ? "加载失败，可重试：" + vm.Load.Error
                : vm.PaginationError ?? $"已加载 {vm.Items.Count} 项" + (vm.HasMore ? "" : "，已到末尾");
            more!.IsEnabled = vm.HasMore && !vm.Load.IsBusy;
        }
        async Task LoadMore()
        {
            var current = vm;
            if (current is null) return;
            more!.IsEnabled = false;
            status.Text = "正在加载…";
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
        var apply = new Button { Content = "筛选", Style = Res<Style>("AccentButtonStyle"), VerticalAlignment = VerticalAlignment.Bottom };
        apply.Click += async (_, _) => await Guard(ApplyFilter);
        var filters = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        filters.Children.Add(kinds); filters.Children.Add(order); filters.Children.Add(sender); filters.Children.Add(apply);
        Details.Children.Add(filters);
        Details.Children.Add(status); Details.Children.Add(content); Details.Children.Add(more);
        await ApplyFilter();
    }
}
