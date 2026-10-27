using System.Collections.ObjectModel;
using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;
using Windows.System;
using ProtoMessage = Qqbridge.V1.Message;

namespace BetterChat;

public sealed record ForwardRow(int Index, ForwardNode Node)
{
    public override string ToString() => Node.SenderName;
}

public sealed partial class MainWindow
{
    private event Action<MediaReadyUpdate>? ForwardMediaReady;
    private readonly SemaphoreSlim forwardPreviews = new(4, 4);

    private async Task ShowForward(ProtoMessage message)
    {
        if (api is not { } sessionApi) return;
        using var closed = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        CancellationTokenSource? pageSource = null;
        var path = new List<int>();
        var rows = new ObservableCollection<ForwardRow>();
        // 顶部一行：返回（嵌套层或媒体）、状态、出错时的重试。加载中只转进度环，不写「正在加载…」「N 条消息」。
        var back = new Button { Content = new FontIcon { Glyph = "\uE72B", FontSize = 14 }, Visibility = Visibility.Collapsed, Padding = new Thickness(8) };
        ToolTipService.SetToolTip(back, "返回上一级"); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(back, "返回上一级");
        var loading = new ProgressRing { IsActive = true, Width = 20, Height = 20 };
        var status = new TextBlock { Style = Res<Style>("SecondaryCaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        var retry = new Button { Content = new FontIcon { Glyph = "\uE72C", FontSize = 14 }, Padding = new Thickness(8), Visibility = Visibility.Collapsed };
        ToolTipService.SetToolTip(retry, "重新加载"); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(retry, "重新加载");
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        header.Children.Add(back); header.Children.Add(loading); header.Children.Add(status); header.Children.Add(retry);
        void Status(string text) { status.Text = text; header.Visibility = back.Visibility == Visibility.Visible || loading.IsActive || text.Length > 0 ? Visibility.Visible : Visibility.Collapsed; }
        var list = new ListView { Height = 450, ItemsSource = rows, SelectionMode = ListViewSelectionMode.None, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        list.ItemTemplate = (DataTemplate)XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ContentControl HorizontalContentAlignment='Stretch' IsTabStop='False'/></DataTemplate>");
        var mediaHost = new ContentControl { Visibility = Visibility.Collapsed, MaxHeight = 450, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var panel = new StackPanel { Spacing = 12, Width = 520 }; panel.Children.Add(header); panel.Children.Add(status); panel.Children.Add(list); panel.Children.Add(mediaHost);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "聊天记录", Content = panel, CloseButtonText = "关闭" };
        var refresh = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        MediaPlayerElement? player = null;
        bool mediaVisible = false;
        void StopMedia() { player?.MediaPlayer?.Pause(); if (player is not null) player.Source = null; player = null; mediaHost.Content = null; }
        void RestoreList()
        {
            StopMedia(); mediaVisible = false; mediaHost.Visibility = Visibility.Collapsed; list.Visibility = Visibility.Visible;
            back.Visibility = path.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            Status("");
        }
        async Task OpenMedia(MediaInfo media, string label)
        {
            string hash = MediaPresentation.OpenHash(media);
            if (hash.Length == 0 && media.Mime.StartsWith("image/")) hash = MediaPresentation.PreviewHash(media);
            if (hash.Length == 0) { Status("媒体还在准备，好了会自动更新"); return; }
            var ct = pageSource?.Token ?? closed.Token;
            var uri = await MediaUri(sessionApi, hash, ct);
            ct.ThrowIfCancellationRequested();
            if (media.Mime.StartsWith("image/")) mediaHost.Content = new Image { Source = new BitmapImage(uri), MaxHeight = 450, Stretch = Stretch.Uniform };
            else if (media.Mime.StartsWith("audio/") || media.Mime.StartsWith("video/"))
            {
                StopMedia(); player = new MediaPlayerElement { AreTransportControlsEnabled = true, AutoPlay = false, Height = media.Mime.StartsWith("audio/") ? 100 : 360, Source = Windows.Media.Core.MediaSource.CreateFromUri(uri) }; mediaHost.Content = player;
            }
            else { await Launcher.LaunchUriAsync(uri); return; }
            Status(label); mediaVisible = true; mediaHost.Visibility = Visibility.Visible; list.Visibility = Visibility.Collapsed; back.Visibility = Visibility.Visible;
        }
        async Task Load(bool changingPath)
        {
            pageSource?.Cancel(); pageSource?.Dispose(); pageSource = CancellationTokenSource.CreateLinkedTokenSource(closed.Token);
            var ct = pageSource.Token;
            if (changingPath) { RestoreList(); rows.Clear(); }
            var request = new GetForwardRequest { ChatId = message.ChatId, Seq = message.Seq }; request.Path.Add(path);
            if (!mediaVisible) { loading.IsActive = true; Status(""); }
            retry.Visibility = Visibility.Collapsed;
            try
            {
                var result = await SessionFor(sessionApi).GetForwardAsync(request, ct); ct.ThrowIfCancellationRequested();
                while (rows.Count > result.Nodes.Count) rows.RemoveAt(rows.Count - 1);
                for (int i = 0; i < result.Nodes.Count; i++)
                {
                    var row = new ForwardRow(i, result.Nodes[i]);
                    if (i >= rows.Count) rows.Add(row); else if (!rows[i].Node.Equals(row.Node)) rows[i] = row;
                }
                loading.IsActive = false;
                if (!mediaVisible) Status(result.Unavailable ? "QQ 已无法提供这份聊天记录" : rows.Count == 0 ? "聊天记录为空" : "");
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!ct.IsCancellationRequested) { loading.IsActive = false; Status("加载失败：" + error.Message); retry.Visibility = Visibility.Visible; } }
        }
        list.ContainerContentChanging += (_, args) =>
        {
            if (args.ItemContainer.ContentTemplateRoot is not ContentControl host) return;
            if (args.InRecycleQueue) { host.Content = null; return; }
            if (args.Item is not ForwardRow row) return;
            // 一条记录和聊天气泡同样排法：头像｜名字、时间｜文字、@、小黄脸在同一段里混排（原来每段各占一行）。
            var node = row.Node;
            string name = node.SenderName.Length > 0 ? node.SenderName : node.SenderId.ToString();
            var item = new Grid { ColumnSpacing = 10, Margin = new Thickness(0, 8, 0, 8) };
            item.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            item.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var avatar = new PersonPicture { Width = 32, Height = 32, DisplayName = name, Tag = node.SenderId, VerticalAlignment = VerticalAlignment.Top };
            if (node.SenderId > 0) avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, node.SenderId);
            item.Children.Add(avatar);
            var body = new StackPanel { Spacing = 6 };
            Grid.SetColumn(body, 1); item.Children.Add(body);
            var title = new Grid { ColumnSpacing = 8 };
            title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            title.Children.Add(new TextBlock { Text = name, Style = Res<Style>("BodyStrongTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis });
            var when = new TextBlock { Text = ChatPresentationTime(node.Time), Style = Res<Style>("SecondaryCaptionTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(when, 1); title.Children.Add(when);
            body.Children.Add(title);
            Paragraph? paragraph = null;
            void Inline(Inline inline)
            {
                if (paragraph is null)
                {
                    paragraph = new Paragraph();
                    var rich = new RichTextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
                    rich.Blocks.Add(paragraph); body.Children.Add(rich);
                }
                paragraph.Inlines.Add(inline);
            }
            foreach (var segment in node.Segments)
            {
                if (segment.Text is null && segment.Mention is null && segment.MentionAll is null && segment.Face is null) paragraph = null;
                if (segment.Text is { } text) Inline(new Run { Text = text.Text });
                else if (segment.Mention is { } at) Inline(new Run { Text = "@" + (at.Name.Length > 0 ? at.Name : PeerName(at.UserId, Scene.Friend)) + " ", Foreground = Brush("AccentTextFillColorPrimaryBrush") });
                else if (segment.MentionAll is not null) Inline(new Run { Text = "@全体成员 ", Foreground = Brush("AccentTextFillColorPrimaryBrush") });
                else if (segment.Face is { } face)
                {
                    if (FaceImage(face.FaceId) is { } picture) Inline(new InlineUIContainer { Child = picture });
                    else Inline(new Run { Text = "[" + (face.Name.Length > 0 ? face.Name : "表情 " + face.FaceId) + "]" });
                }
                else if (segment.Markdown is { } markdown) body.Children.Add(new TextBlock { Text = markdown.Content, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                else if (segment.Forward is { } nested)
                {
                    int index = row.Index;
                    body.Children.Add(ForwardCard(nested, Brush("SubtleFillColorSecondaryBrush"), Brush("TextFillColorPrimaryBrush"), async () =>
                    {
                        if (path.Count >= 8) { Status("已达到服务端支持的嵌套层数"); return; }
                        path.Add(index); await Load(true);
                    }));
                }
                else if (Media(segment) is { } media)
                {
                    string label = segment.File?.Name ?? (segment.Record is not null ? "语音" : segment.Video is not null ? "视频" : "图片");
                    string preview = MediaPresentation.PreviewHash(media);
                    // 有预览就只放画面；没有预览（文件、语音、还没准备好的）才写名称和状态。
                    var content = new StackPanel { Spacing = 6 };
                    if (preview.Length == 0)
                    {
                        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                        line.Children.Add(new FontIcon { Glyph = segment.Record is not null ? "\uE720" : segment.Video is not null ? "\uE714" : segment.File is not null ? FileGlyph(label) : "\uEB9F", FontSize = 16 });
                        line.Children.Add(new TextBlock { Text = label, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 300 });
                        content.Children.Add(line);
                        if (media.State != MediaState.Stored) content.Children.Add(new TextBlock { Text = MediaPresentation.StateText(media.State), Style = Res<Style>("SecondaryCaptionTextBlockStyle") });
                    }
                    var button = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = preview.Length > 0 ? new Thickness(0) : new Thickness(10, 8, 10, 8) };
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
                    button.Click += async (_, _) => { try { await OpenMedia(media, label); } catch (OperationCanceledException) { } catch (Exception error) { Status(error.Message); } };
                    if (preview.Length > 0)
                    {
                        var image = new Image { MaxHeight = 180, MaxWidth = 280, Stretch = Stretch.Uniform };
                        content.Children.Add(new Border { CornerRadius = Res<object>("ControlCornerRadius") is CornerRadius r ? r : new CornerRadius(4), Child = image, MinWidth = 80, MinHeight = 60, Background = Brush("SubtleFillColorSecondaryBrush") });
                        if (segment.Video is not null) content.Children.Add(new FontIcon { Glyph = "\uE768", FontSize = 14, HorizontalAlignment = HorizontalAlignment.Left });
                        CancellationTokenSource? visible = null;
                        button.Loaded += async (_, _) =>
                        {
                            visible?.Cancel(); visible?.Dispose(); visible = CancellationTokenSource.CreateLinkedTokenSource(closed.Token);
                            var ct = visible.Token;
                            try
                            {
                                await forwardPreviews.WaitAsync(ct);
                                try { var uri = await PreviewUri(sessionApi, preview, ct); ct.ThrowIfCancellationRequested(); image.Source = new BitmapImage(uri) { DecodePixelWidth = 560 }; }
                                finally { forwardPreviews.Release(); }
                            }
                            catch (OperationCanceledException) { }
                            catch (Exception) { }
                        };
                        button.Unloaded += (_, _) => { visible?.Cancel(); visible?.Dispose(); visible = null; };
                    }
                    body.Children.Add(button);
                    paragraph = null;
                }
                else Inline(new Run { Text = "[暂不支持的内容]", Foreground = Brush("TextFillColorSecondaryBrush") });
            }
            host.Content = item; args.Handled = true;
        };
        back.Click += async (_, _) => { if (mediaVisible) RestoreList(); else if (path.Count > 0) { path.RemoveAt(path.Count - 1); await Load(true); } };
        retry.Click += async (_, _) => await Load(false);
        refresh.Tick += async (_, _) => { refresh.Stop(); if (!closed.IsCancellationRequested) await Load(false); };
        void Ready(MediaReadyUpdate update)
        {
            if (update.ChatId == message.ChatId && update.Seq == message.Seq && update.Node >= 0 && update.ForwardPath == string.Join('.', path)) { refresh.Stop(); refresh.Start(); }
        }
        ForwardMediaReady += Ready;
        dialog.Opened += async (_, _) => await Load(true);
        dialog.Closed += (_, _) => { closed.Cancel(); pageSource?.Cancel(); refresh.Stop(); StopMedia(); };
        try { await dialog.ShowAsync(); }
        finally { ForwardMediaReady -= Ready; closed.Cancel(); pageSource?.Cancel(); pageSource?.Dispose(); refresh.Stop(); StopMedia(); }
    }
}
