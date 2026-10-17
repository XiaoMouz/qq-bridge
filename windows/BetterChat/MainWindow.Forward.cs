using System.Collections.ObjectModel;
using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    private async Task SelectMessagesToForward(BetterChat.Infrastructure.ClientSessionRuntime session, long chat)
    {
        if (runtime != session || selectedChat != chat || historyWindow is not { } window) return;
        var ct = pageTask?.Token ?? lifetime.Token;
        var snapshot = await session.Repository.GetTimelineAsync(window.Capture(chat) with { IncludeOutgoing = false }, ct);
        ct.ThrowIfCancellationRequested();
        if (runtime != session || selectedChat != chat || historyWindow != window) return;
        var candidates = snapshot.Messages.Where(m => m.State == MessageState.Normal).OrderBy(m => m.Seq)
            .Select(m => new ListEntry(m.SenderName + " · #" + m.Seq + " · " + (m.Text.Length > 0 ? m.Text : "[媒体消息]"), "", "", m)).ToArray();
        if (candidates.Length == 0) { await DialogBox("多选转发", Text("当前历史窗口没有可转发消息。")); return; }
        var selection = new ListView { ItemsSource = candidates, DisplayMemberPath = "Title", SelectionMode = ListViewSelectionMode.Multiple, Height = 400, Width = 480 };
        var count = Text("请选择 1 至 100 条消息。", 12);
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(Text("仅列出当前已加载的历史窗口；需要更早的消息时，先返回聊天加载历史。", 12)); panel.Children.Add(selection); panel.Children.Add(count);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "选择转发消息", Content = panel, PrimaryButtonText = "选择目标", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        selection.SelectionChanged += (_, _) =>
        {
            count.Text = $"已选择 {selection.SelectedItems.Count} 条（最多 100 条）";
            dialog.IsPrimaryButtonEnabled = selection.SelectedItems.Count is > 0 and <= 100;
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        ct.ThrowIfCancellationRequested();
        if (runtime != session || selectedChat != chat) return;
        var sequences = selection.SelectedItems.Cast<ListEntry>().Select(row => ((ProtoMessage)row.Value).Seq).Distinct().Order().ToArray();
        await Forward(session, chat, sequences);
    }
    private event Action<MediaReadyUpdate>? ForwardMediaReady;
    private readonly SemaphoreSlim forwardPreviews = new(4, 4);

    private async Task ShowForward(ProtoMessage message)
    {
        if (api is not { } sessionApi) return;
        using var closed = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        CancellationTokenSource? pageSource = null;
        var path = new List<int>();
        var rows = new ObservableCollection<ForwardRow>();
        var back = new Button { Content = "返回上一级", Visibility = Visibility.Collapsed };
        var status = Text("正在加载聊天记录…", 12);
        var retry = new Button { Content = "重新加载" };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 }; header.Children.Add(back); header.Children.Add(retry);
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
        }
        async Task OpenMedia(MediaInfo media, string label)
        {
            string hash = MediaPresentation.OpenHash(media);
            if (hash.Length == 0 && media.Mime.StartsWith("image/")) hash = MediaPresentation.PreviewHash(media);
            if (hash.Length == 0) { status.Text = "媒体仍在准备，完成后会自动更新。"; return; }
            var ct = pageSource?.Token ?? closed.Token;
            var uri = await MediaUri(sessionApi, hash, ct);
            ct.ThrowIfCancellationRequested();
            if (media.Mime.StartsWith("image/")) mediaHost.Content = new Image { Source = new BitmapImage(uri), MaxHeight = 450, Stretch = Stretch.Uniform };
            else if (media.Mime.StartsWith("audio/") || media.Mime.StartsWith("video/"))
            {
                StopMedia(); player = new MediaPlayerElement { AreTransportControlsEnabled = true, AutoPlay = false, Height = media.Mime.StartsWith("audio/") ? 100 : 360, Source = Windows.Media.Core.MediaSource.CreateFromUri(uri) }; mediaHost.Content = player;
            }
            else { await Launcher.LaunchUriAsync(uri); return; }
            status.Text = label; mediaVisible = true; mediaHost.Visibility = Visibility.Visible; list.Visibility = Visibility.Collapsed; back.Visibility = Visibility.Visible;
        }
        async Task Load(bool changingPath)
        {
            pageSource?.Cancel(); pageSource?.Dispose(); pageSource = CancellationTokenSource.CreateLinkedTokenSource(closed.Token);
            var ct = pageSource.Token;
            if (changingPath) { RestoreList(); rows.Clear(); }
            var request = new GetForwardRequest { ChatId = message.ChatId, Seq = message.Seq }; request.Path.Add(path);
            if (!mediaVisible) status.Text = "正在加载聊天记录…";
            retry.IsEnabled = false;
            try
            {
                var result = await SessionFor(sessionApi).GetForwardAsync(request, ct); ct.ThrowIfCancellationRequested();
                while (rows.Count > result.Nodes.Count) rows.RemoveAt(rows.Count - 1);
                for (int i = 0; i < result.Nodes.Count; i++)
                {
                    var row = new ForwardRow(i, result.Nodes[i]);
                    if (i >= rows.Count) rows.Add(row); else if (!rows[i].Node.Equals(row.Node)) rows[i] = row;
                }
                if (!mediaVisible) status.Text = result.Unavailable ? "QQ 已无法提供这份聊天记录。" : rows.Count == 0 ? "聊天记录为空。" : $"{rows.Count} 条消息";
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!ct.IsCancellationRequested) status.Text = "加载失败，可点击重新加载。" + error.Message; }
            finally { if (!ct.IsCancellationRequested) retry.IsEnabled = true; }
        }
        list.ContainerContentChanging += (_, args) =>
        {
            if (args.ItemContainer.ContentTemplateRoot is not ContentControl host) return;
            if (args.InRecycleQueue) { host.Content = null; return; }
            if (args.Item is not ForwardRow row) return;
            var body = new StackPanel { Spacing = 8, Margin = new Thickness(4, 12, 4, 12) };
            body.Children.Add(Text((row.Node.SenderName.Length > 0 ? row.Node.SenderName : row.Node.SenderId.ToString()) + " · " + DateTimeOffset.FromUnixTimeSeconds(row.Node.Time).ToLocalTime().ToString("MM-dd HH:mm"), 12));
            foreach (var segment in row.Node.Segments)
            {
                if (segment.Text is { } text) body.Children.Add(Text(text.Text));
                else if (segment.Mention is { } at) body.Children.Add(Text("@" + (at.Name.Length > 0 ? at.Name : at.UserId.ToString())));
                else if (segment.MentionAll is not null) body.Children.Add(Text("@全体成员"));
                else if (segment.Face is { } face) body.Children.Add((UIElement?)FaceImage(face.FaceId) ?? Text("[" + (face.Name.Length > 0 ? face.Name : face.FaceId) + "]"));
                else if (segment.Markdown is { } markdown) body.Children.Add(Text(markdown.Content));
                else if (segment.Forward is { } nested)
                {
                    int node = row.Index;
                    body.Children.Add(ActionButton(nested.Title.Length > 0 ? nested.Title : "嵌套聊天记录", async () =>
                    {
                        if (path.Count >= 8) { status.Text = "已达到服务端支持的嵌套层数。"; return; }
                        path.Add(node); await Load(true);
                    }));
                }
                else if (Media(segment) is { } media)
                {
                    string label = segment.File?.Name ?? (segment.Record is not null ? "语音" : segment.Video is not null ? "视频" : "图片");
                    var content = new StackPanel { Spacing = 6 }; content.Children.Add(Text(label));
                    content.Children.Add(Text(MediaPresentation.StateText(media.State), 12));
                    var button = new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Left };
                    button.Click += async (_, _) => { try { await OpenMedia(media, label); } catch (OperationCanceledException) { } catch (Exception error) { status.Text = error.Message; } };
                    string preview = MediaPresentation.PreviewHash(media);
                    if (preview.Length > 0)
                    {
                        var image = new Image { MaxHeight = 180, MaxWidth = 280, Stretch = Stretch.Uniform }; content.Children.Insert(0, image);
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
                }
                else body.Children.Add(Text("[暂不支持的内容]"));
            }
            host.Content = body; args.Handled = true;
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
