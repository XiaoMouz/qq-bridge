using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;
using Windows.ApplicationModel.DataTransfer;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Pickers;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;
using Windows.System;
using ProtoMessage = Qqbridge.V1.Message;

namespace BetterChat;

// 看图 / 看视频浮层（代替原来的对话框和交给系统程序），以及气泡里的语音条。
public sealed partial class MainWindow
{
    // Direct：群公告 / 精华里的图片是 QQ 的公开链接，没有对应的消息媒体，直接下载。
    private sealed record ViewerItem(ProtoMessage Message, MediaInfo Media, bool Video, Uri? Direct = null);
    private List<ViewerItem> viewerItems = [];
    private int viewerIndex;
    private Uri? viewerUri;
    private CancellationTokenSource? viewerLoad;
    // 一次打开查看器的生命周期：预取的相邻图片用它，左右切换不取消预取，关闭时才取消。
    private CancellationTokenSource? viewerSession;
    // 当前和相邻图片的原图数据（同 iOS：看大图只加载当前和左右各一张）。按媒体定键，切换后不在相邻范围的丢掉。
    private readonly Dictionary<(long Chat, long Seq, uint Ord), Task<(Uri Uri, byte[] Bytes)>> viewerData = [];
    private byte[]? viewerBytes;
    private static readonly HttpClient MediaDownloads = new() { Timeout = TimeSpan.FromMinutes(5) };

    private static bool IsViewable(MediaInfo media, Segment s) => s.Image is not null || s.MarketFace is not null || s.Video is not null
        || media.Mime.StartsWith("image/", StringComparison.OrdinalIgnoreCase) || media.Mime.StartsWith("video/", StringComparison.OrdinalIgnoreCase);

    // 打开查看器：把当前历史窗口里的图片和视频按顺序排好，左右切换。
    private async Task OpenViewer(ProtoMessage message, MediaInfo media)
    {
        var items = new List<ViewerItem>();
        foreach (var m in timelineMessages.Values.Where(x => x.ChatId == message.ChatId).OrderBy(x => x.Seq))
            foreach (var s in m.Segments)
                if (Media(s) is { } info && IsViewable(info, s))
                    items.Add(new(m, info, s.Video is not null || info.Mime.StartsWith("video/", StringComparison.OrdinalIgnoreCase)));
        int index = items.FindIndex(x => x.Message.Seq == message.Seq && x.Media.Ord == media.Ord);
        if (index < 0)
        {
            items = [new(message, media, media.Mime.StartsWith("video/", StringComparison.OrdinalIgnoreCase))];
            index = 0;
        }
        await OpenViewer(items, index);
    }

    // 公告、精华里的一组公开图片：用同一个查看器（缩放、左右切换、复制、另存），代替原来的对话框。
    private Task OpenPublicImages(IReadOnlyList<Uri> images, int index, string sender, long time)
    {
        var message = new ProtoMessage { SenderName = sender, Time = time };
        return OpenViewer(images.Select((uri, i) => new ViewerItem(message, new MediaInfo { Ord = (uint)i, Mime = "image/*" }, false, uri)).ToList(), index);
    }

    private async Task OpenViewer(List<ViewerItem> items, int index)
    {
        viewerItems = items;
        viewerSession?.Cancel(); viewerSession?.Dispose();
        viewerSession = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        viewerData.Clear();
        Viewer.Visibility = Visibility.Visible;
        Viewer.Focus(FocusState.Programmatic);
        await ShowViewerItem(index);
    }

    private async Task ShowViewerItem(int index)
    {
        if (index < 0 || index >= viewerItems.Count || api is not { } sessionApi) return;
        viewerIndex = index;
        viewerLoad?.Cancel(); viewerLoad?.Dispose();
        viewerLoad = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var ct = viewerLoad.Token;
        var item = viewerItems[index];
        ViewerTitle.Text = SenderDisplay(item.Message);
        ViewerSubtitle.Text = DateTimeOffset.FromUnixTimeSeconds(item.Message.Time).ToLocalTime().ToString("yyyy-MM-dd HH:mm") + $" · {index + 1} / {viewerItems.Count}";
        ViewerPrevious.Visibility = index > 0 ? Visibility.Visible : Visibility.Collapsed;
        ViewerNext.Visibility = index < viewerItems.Count - 1 ? Visibility.Visible : Visibility.Collapsed;
        ViewerZoomIn.Visibility = ViewerZoomOut.Visibility = ViewerCopy.Visibility = item.Video ? Visibility.Collapsed : Visibility.Visible;
        ViewerForward.Visibility = item.Direct is null ? Visibility.Visible : Visibility.Collapsed;
        StopViewerPlayer();
        ViewerImage.Source = null; ViewerError.Visibility = Visibility.Collapsed; viewerUri = null; viewerBytes = null;
        ViewerScroll.Visibility = item.Video ? Visibility.Collapsed : Visibility.Visible;
        ViewerPlayer.Visibility = item.Video ? Visibility.Visible : Visibility.Collapsed;
        ViewerLoading.IsActive = true;
        try
        {
            if (item.Video)
            {
                var uri = await ViewerUri(sessionApi, item, ct);
                if (api != sessionApi || viewerIndex != index || Viewer.Visibility != Visibility.Visible) return;
                viewerUri = uri; ViewerPlayer.Source = MediaSource.CreateFromUri(uri);
            }
            else
            {
                var (uri, bytes) = await ViewerImageData(sessionApi, item).WaitAsync(ct);
                var bitmap = new BitmapImage();
                using (var stream = new InMemoryRandomAccessStream())
                {
                    await stream.WriteAsync(bytes.AsBuffer()); stream.Seek(0);
                    await bitmap.SetSourceAsync(stream);
                }
                ct.ThrowIfCancellationRequested();
                if (api != sessionApi || viewerIndex != index || Viewer.Visibility != Visibility.Visible) return;
                viewerUri = uri; viewerBytes = bytes;
                ViewerImage.Source = bitmap; FitViewerImage();
            }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error) { if (viewerIndex == index) ShowViewerError(error.Message); return; }
        ViewerLoading.IsActive = false;
        PreloadViewerNeighbors(sessionApi, index);
    }

    // 打开前先让服务端准备好原图（还没下好时退回预览图，同 iOS），再拿签名地址。
    private async Task<Uri> ViewerUri(BridgeApi sessionApi, ViewerItem item, CancellationToken ct)
    {
        if (item.Direct is { } direct) return direct;
        var media = await SessionFor(sessionApi).PrepareMediaForOpenAsync(item.Message.ChatId, item.Message.Seq, item.Media, ct);
        string sha = media.State == MediaState.Stored ? MediaPresentation.OpenHash(media) : "";
        if (sha.Length == 0 && !item.Video) sha = MediaPresentation.PreviewHash(media);
        if (sha.Length == 0) throw new IOException("媒体暂不可用：" + MediaPresentation.StateText(media.State));
        var uri = await MediaUri(sessionApi, sha, ct);
        ct.ThrowIfCancellationRequested();
        return uri;
    }
    private Task<(Uri Uri, byte[] Bytes)> ViewerImageData(BridgeApi sessionApi, ViewerItem item)
    {
        var key = (item.Message.ChatId, item.Message.Seq, item.Media.Ord);
        if (viewerData.TryGetValue(key, out var task) && !task.IsFaulted && !task.IsCanceled) return task;
        var ct = viewerSession?.Token ?? lifetime.Token;
        task = Load();
        viewerData[key] = task;
        return task;
        async Task<(Uri, byte[])> Load()
        {
            var uri = await ViewerUri(sessionApi, item, ct);
            return (uri, await MediaDownloads.GetByteArrayAsync(uri, ct));
        }
    }
    // 预取左右各一张图片（视频不预取），其余的数据丢掉，内存里最多三张原图。
    private void PreloadViewerNeighbors(BridgeApi sessionApi, int index)
    {
        var keep = new HashSet<(long, long, uint)>();
        for (int i = Math.Max(0, index - 1); i <= Math.Min(viewerItems.Count - 1, index + 1); i++)
        {
            var item = viewerItems[i];
            keep.Add((item.Message.ChatId, item.Message.Seq, item.Media.Ord));
            if (i != index && !item.Video) _ = ViewerImageData(sessionApi, item).ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
        }
        foreach (var key in viewerData.Keys.Where(k => !keep.Contains(k)).ToList()) viewerData.Remove(key);
    }

    private void ShowViewerError(string message)
    {
        ViewerLoading.IsActive = false;
        ViewerError.Text = message; ViewerError.Visibility = Visibility.Visible;
    }

    // 图片先按窗口大小完整显示（不放大小图），之后用户自己缩放。
    private void FitViewerImage()
    {
        if (ViewerImage.Source is not BitmapImage { PixelWidth: > 0, PixelHeight: > 0 } bitmap) return;
        double scale = Root.XamlRoot?.RasterizationScale ?? 1;
        double width = bitmap.PixelWidth / scale, height = bitmap.PixelHeight / scale;
        ViewerImage.Width = width; ViewerImage.Height = height;
        double fit = Math.Min(1, Math.Min((ViewerScroll.ActualWidth - 32) / width, (ViewerScroll.ActualHeight - 32) / height));
        ViewerScroll.ChangeView(0, 0, (float)Math.Max(ViewerScroll.MinZoomFactor, fit), true);
    }

    private void CloseViewer()
    {
        viewerLoad?.Cancel(); viewerSession?.Cancel(); viewerData.Clear(); viewerBytes = null;
        StopViewerPlayer();
        ViewerImage.Source = null; viewerUri = null; viewerItems = [];
        Viewer.Visibility = Visibility.Collapsed;
    }
    private void StopViewerPlayer()
    {
        ViewerPlayer.MediaPlayer?.Pause();
        ViewerPlayer.Source = null;
    }

    private void ViewerKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Escape: CloseViewer(); break;
            case VirtualKey.Left: _ = Guard(() => ShowViewerItem(viewerIndex - 1)); break;
            case VirtualKey.Right: _ = Guard(() => ShowViewerItem(viewerIndex + 1)); break;
            default: return;
        }
        e.Handled = true;
    }
    private void ViewerCloseClicked(object sender, RoutedEventArgs e) => CloseViewer();
    private async void ViewerStepClicked(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string step && int.TryParse(step, out int delta)) await Guard(() => ShowViewerItem(viewerIndex + delta));
    }
    private void ViewerZoomClicked(object sender, RoutedEventArgs e)
    {
        float factor = (sender as FrameworkElement)?.Tag as string == "in" ? 1.5f : 1 / 1.5f;
        ViewerScroll.ChangeView(null, null, Math.Clamp(ViewerScroll.ZoomFactor * factor, ViewerScroll.MinZoomFactor, ViewerScroll.MaxZoomFactor));
    }
    // 双击：适应窗口和 100% 之间切换。
    private void ViewerDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (Math.Abs(ViewerScroll.ZoomFactor - 1) > 0.01) ViewerScroll.ChangeView(null, null, 1);
        else FitViewerImage();
    }

    private async Task<byte[]?> DownloadViewerItem()
    {
        // 图片已经整张下载在内存里，复制 / 另存不再下载第二遍。
        if (viewerBytes is { } bytes) return bytes;
        if (viewerUri is not { } uri) return null;
        return await MediaDownloads.GetByteArrayAsync(uri, lifetime.Token);
    }
    private async void ViewerCopyClicked(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (await DownloadViewerItem() is not { } bytes) return;
        var stream = new InMemoryRandomAccessStream();
        await stream.WriteAsync(bytes.AsBuffer()); stream.Seek(0);
        var data = new DataPackage(); data.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
        Clipboard.SetContent(data);
        Notice.Severity = InfoBarSeverity.Success; Notice.Message = "已复制图片"; Notice.IsOpen = true;
    });
    private async void ViewerSaveClicked(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (viewerIndex >= viewerItems.Count) return;
        var item = viewerItems[viewerIndex];
        string extension = item.Media.Mime switch { "image/png" => ".png", "image/gif" => ".gif", "image/webp" => ".webp", "video/mp4" => ".mp4", _ => item.Video ? ".mp4" : ".jpg" };
        var picker = new FileSavePicker { SuggestedFileName = $"BetterChat-{item.Message.ChatId}-{item.Message.Seq}" };
        picker.FileTypeChoices.Add(item.Video ? "视频" : "图片", [extension]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file is null || await DownloadViewerItem() is not { } bytes) return;
        await Windows.Storage.FileIO.WriteBytesAsync(file, bytes);
        Notice.Severity = InfoBarSeverity.Success; Notice.Message = "已保存到 " + file.Path; Notice.IsOpen = true;
    });
    private async void ViewerForwardClicked(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (runtime is not { } session || viewerIndex >= viewerItems.Count || viewerItems[viewerIndex].Direct is not null) return;
        var item = viewerItems[viewerIndex];
        await Forward(session, item.Message.ChatId, [item.Message.Seq]);
    });
    private async void ViewerOpenClicked(object sender, RoutedEventArgs e)
    {
        if (viewerUri is { } uri) await Launcher.LaunchUriAsync(uri);
    }

    // —— 语音条 ——
    // 同一时间只播一条语音；切换会话、退出账号、开始播另一条时停止上一条。
    private MediaPlayer? voicePlayer;
    private VoiceUi? playingVoice;
    private sealed class VoiceUi(ProtoMessage message, MediaInfo media, FontIcon icon, ProgressBar progress, TextBlock time, double duration)
    {
        public ProtoMessage Message { get; } = message;
        public MediaInfo Media { get; } = media;
        public FontIcon Icon { get; } = icon;
        public ProgressBar Progress { get; } = progress;
        public TextBlock Time { get; } = time;
        public double Duration { get; } = duration;
    }

    // 语音条：播放 / 暂停、进度、时长，右边「转文字」，结果显示在下面（iOS 的语音气泡）。
    private FrameworkElement VoiceView(ProtoMessage m, RecordSegment record, MediaInfo media, bool own, Brush foreground, CancellationToken pageToken)
    {
        double duration = Math.Max(1, record.DurationSec);
        var icon = new FontIcon { Glyph = "", FontSize = 14, Foreground = own ? Brush("AccentFillColorDefaultBrush") : Brush("TextOnAccentFillColorPrimaryBrush") };
        var play = new Button
        {
            Content = icon, Width = 32, Height = 32, Padding = new Thickness(0), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(0),
            Background = own ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("AccentFillColorDefaultBrush")
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(play, "播放语音");
        var progress = new ProgressBar { Minimum = 0, Maximum = 1, Value = 0, Width = Math.Clamp(80 + duration * 4, 100, 220), VerticalAlignment = VerticalAlignment.Center };
        // 强调色底上的轨道用半透明白，默认的深色轨道看不清（2026-10-19 实测）。
        if (own) { progress.Foreground = Brush("TextOnAccentFillColorPrimaryBrush"); progress.Background = OnAccentOverlay; }
        var time = new TextBlock { Text = $"{(int)duration}″", Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground, VerticalAlignment = VerticalAlignment.Center };
        var transcribe = new Button { Content = new TextBlock { Text = "转文字", Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground }, Padding = new Thickness(8, 2, 8, 2), MinHeight = 0, Background = own ? OnAccentOverlay : Brush("SubtleFillColorSecondaryBrush"), BorderThickness = new Thickness(0) };
        var transcript = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = foreground, IsTextSelectionEnabled = true, Visibility = Visibility.Collapsed, MaxWidth = 360 };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(play); row.Children.Add(progress); row.Children.Add(time); row.Children.Add(transcribe);
        var panel = new StackPanel { Spacing = 6 }; panel.Children.Add(row); panel.Children.Add(transcript);
        var ui = new VoiceUi(m, media, icon, progress, time, duration);
        play.Click += async (_, _) => await Guard(() => ToggleVoice(ui, pageToken));
        transcribe.Click += async (_, _) => await Guard(async () =>
        {
            if (runtime is not { } session) return;
            transcribe.IsEnabled = false; transcript.Text = "正在识别…"; transcript.Visibility = Visibility.Visible;
            try
            {
                var result = await session.TranscribeVoiceAsync(new() { ChatId = m.ChatId, Seq = m.Seq }, pageToken);
                transcript.Text = result.Text.Length > 0 ? result.Text : "没有识别出文字";
                transcribe.Visibility = Visibility.Collapsed;
            }
            catch { transcript.Text = "识别失败，可以再试一次"; transcribe.IsEnabled = true; throw; }
        });
        return panel;
    }

    private async Task ToggleVoice(VoiceUi ui, CancellationToken ct)
    {
        if (api is not { } sessionApi) return;
        if (playingVoice is { } current && current.Message.Seq == ui.Message.Seq && current.Message.ChatId == ui.Message.ChatId && voicePlayer is { } active)
        {
            playingVoice = ui;
            if (active.PlaybackSession.PlaybackState == MediaPlaybackState.Playing) { active.Pause(); ui.Icon.Glyph = ""; }
            else { active.Play(); ui.Icon.Glyph = ""; }
            return;
        }
        StopVoice();
        playingVoice = ui; ui.Icon.Glyph = ""; // 准备中
        var media = await SessionFor(sessionApi).PrepareMediaForOpenAsync(ui.Message.ChatId, ui.Message.Seq, ui.Media, ct);
        string sha = media.State == MediaState.Stored ? MediaPresentation.OpenHash(media) : "";
        if (sha.Length == 0) { ui.Icon.Glyph = ""; throw new IOException("语音暂不可用：" + MediaPresentation.StateText(media.State)); }
        var uri = await MediaUri(sessionApi, sha, ct);
        ct.ThrowIfCancellationRequested();
        if (playingVoice != ui) return;
        voicePlayer ??= CreateVoicePlayer();
        voicePlayer.Source = MediaSource.CreateFromUri(uri);
        voicePlayer.Play();
        ui.Icon.Glyph = "";
    }

    private MediaPlayer CreateVoicePlayer()
    {
        var player = new MediaPlayer { AutoPlay = false };
        // 播放器回调在后台线程：先取出数值，再回到 UI 线程更新当前那条语音。
        player.PlaybackSession.PositionChanged += (session, _) =>
        {
            double position = session.Position.TotalSeconds, total = session.NaturalDuration.TotalSeconds;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (playingVoice is not { } ui) return;
                double length = total > 0 ? total : ui.Duration;
                ui.Progress.Value = Math.Clamp(position / length, 0, 1);
                ui.Time.Text = $"{(int)position}″ / {(int)length}″";
            });
        };
        player.MediaEnded += (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            if (playingVoice is not { } ui) return;
            ui.Icon.Glyph = ""; ui.Progress.Value = 0; ui.Time.Text = $"{(int)ui.Duration}″";
        });
        player.MediaFailed += (_, args) =>
        {
            string error = args.ErrorMessage;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (playingVoice is { } ui) ui.Icon.Glyph = "";
                Notice.Severity = InfoBarSeverity.Error; Notice.Message = "语音播放失败：" + error; Notice.IsOpen = true;
            });
        };
        return player;
    }

    private void StopVoice()
    {
        if (playingVoice is { } ui) { ui.Icon.Glyph = ""; ui.Progress.Value = 0; ui.Time.Text = $"{(int)ui.Duration}″"; }
        playingVoice = null;
        if (voicePlayer is { } player) { player.Pause(); player.Source = null; }
    }
}
