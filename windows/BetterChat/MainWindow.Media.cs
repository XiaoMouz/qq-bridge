using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private BetterChat.Infrastructure.ClientSessionRuntime SessionFor(BridgeApi source)
        => runtime is { } session && session.Api == source ? session : throw new OperationCanceledException("账号已切换。");
    private readonly HashSet<(long Chat, long Seq, uint Ord)> requestedPreviews = [];
    private readonly Dictionary<string, (Uri Uri, long Expires)> signedMedia = [];
    private Task<Uri> PreviewUri(BridgeApi sessionApi, string sha, CancellationToken ct)
    {
        var session = runtime;
        if (session is null || session.Api != sessionApi) throw new OperationCanceledException("账号已切换。", ct);
        return session.GetPreviewUriAsync(sha, ct);
    }

    private async Task<Uri> MediaUri(BridgeApi sessionApi, string sha, CancellationToken ct)
    {
        if (signedMedia.TryGetValue(sha, out var cached) && cached.Expires > DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 60)
            return cached.Uri;
        var request = new SignMediaUrlsRequest(); request.Sha256.Add(sha);
        var result = await SessionFor(sessionApi).SignMediaUrlsAsync(request, ct);
        ct.ThrowIfCancellationRequested();
        var signed = result.Urls.FirstOrDefault(u => u.Sha256 == sha);
        if (signed is null || signed.Url.Length == 0) throw new IOException("服务器未返回媒体地址。");
        var uri = sessionApi.Transport.ResolveMedia(signed.Url);
        if (api == sessionApi)
        {
            if (signedMedia.Count >= 512) signedMedia.Clear();
            signedMedia[sha] = (uri, signed.ExpiresAt);
        }
        return uri;
    }

    // 气泡里的图片 / 视频 / 表情包 / 文件。状态全部用图层表达（同 iOS / Mac 的进度环）：加载预览、准备原件时转圈，
    // 失败一个感叹号（原因在提示里），原件已清理一个角标；原来在画面下面写「正在准备媒体…」「点击查看 / 重试」等文字。
    private FrameworkElement MediaPreview(Message message, Segment segment, MediaInfo media, string label)
    {
        var owner = runtime;
        var ownerToken = pageTask?.Token ?? lifetime.Token;
        bool visual = segment.Image is not null || segment.Video is not null || segment.MarketFace is not null;
        var ring = new ProgressRing { IsActive = false, Width = 24, Height = 24, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var failure = new FontIcon { Glyph = "\uE783", FontSize = 20, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush("SystemFillColorCriticalBrush") };
        var picture = new Image { MaxWidth = 300, MaxHeight = 260, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
        FrameworkElement content;
        if (visual)
        {
            double width = media.Width > 0 ? Math.Min(300, media.Width) : 240;
            double height = media.Width > 0 && media.Height > 0 ? Math.Min(260, width * media.Height / media.Width) : 180;
            picture.Width = width; picture.Height = height;
            var frame = new Grid { CornerRadius = new CornerRadius(6), HorizontalAlignment = HorizontalAlignment.Left, Background = Brush("SubtleFillColorSecondaryBrush") };
            frame.Children.Add(picture);
            if (segment.Video is not null)
                frame.Children.Add(new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(22), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x99, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    Child = new FontIcon { Glyph = "\uE768", FontSize = 18, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) } });
            if (media.State == MediaState.Purged)
            {
                var purged = new Border { Margin = new Thickness(6), Padding = new Thickness(4), CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x99, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
                    Child = new FontIcon { Glyph = "\uE74D", FontSize = 12, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) } };
                ToolTipService.SetToolTip(purged, "原件已清理，只有预览");
                frame.Children.Add(purged);
            }
            frame.Children.Add(ring); frame.Children.Add(failure);
            content = frame;
        }
        else
        {
            // 文件 / 语音以外的附件：图标｜名称、大小｜状态。
            var row = new Grid { ColumnSpacing = 10, MinWidth = 200 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new FontIcon { Glyph = segment.File is not null ? FileGlyph(label) : "\uE8A5", FontSize = 24, VerticalAlignment = VerticalAlignment.Center });
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = label, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 240 });
            if (media.Size > 0) text.Children.Add(new TextBlock { Text = Bytes(media.Size), Style = Res<Style>("SecondaryCaptionTextBlockStyle") });
            Grid.SetColumn(text, 1); row.Children.Add(text);
            Grid.SetColumn(ring, 2); row.Children.Add(ring);
            Grid.SetColumn(failure, 2); row.Children.Add(failure);
            content = row;
        }
        var button = visual
            ? new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(0), MaxWidth = 320, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) }
            : new Button { Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(10, 8, 10, 8), MaxWidth = 320 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        void Busy(bool on) { ring.IsActive = on; ring.Visibility = on ? Visibility.Visible : Visibility.Collapsed; if (on) failure.Visibility = Visibility.Collapsed; }
        void Fail(string reason) { Busy(false); failure.Visibility = Visibility.Visible; ToolTipService.SetToolTip(failure, reason); }
        bool opening = false;
        button.Click += async (_, _) =>
        {
            if (opening || owner is null || runtime != owner || ownerToken.IsCancellationRequested) return;
            opening = true; Busy(true);
            try
            {
                if (visual) await OpenViewer(message, media); else await ShowMedia(message, media, label);
                Busy(false);
            }
            catch (OperationCanceledException) { Busy(false); }
            catch (Exception error)
            {
                if (!ownerToken.IsCancellationRequested && runtime == owner) { Fail(error.Message); Notice.Severity = InfoBarSeverity.Error; Notice.Message = error.Message; Notice.IsOpen = true; }
            }
            finally { opening = false; }
        };
        bool started = false;
        CancellationTokenSource? load = null;
        button.Loaded += async (_, _) =>
        {
            if (started || !visual || owner is null || runtime != owner || ownerToken.IsCancellationRequested) return;
            started = true;
            var currentApi = owner.Api;
            load = CancellationTokenSource.CreateLinkedTokenSource(ownerToken);
            var ct = load.Token;
            try
            {
                string hash = MediaPresentation.PreviewHash(media);
                if (hash.Length > 0)
                {
                    Busy(true);
                    var uri = await PreviewUri(currentApi, hash, ct);
                    ct.ThrowIfCancellationRequested();
                    if (api != currentApi) return;
                    var bitmap = new BitmapImage { DecodePixelWidth = 600 };
                    bitmap.ImageOpened += (_, _) =>
                    {
                        if (ct.IsCancellationRequested) return;
                        Busy(false);
                        // 没有尺寸信息时先按 240×180 占位；图出来后按实际比例收缩，去掉占位底色，避免两侧露灰边。
                        picture.Width = double.NaN; picture.Height = double.NaN;
                        if (picture.Parent is Grid frame) frame.Background = null;
                    };
                    bitmap.ImageFailed += (_, _) => { if (!ct.IsCancellationRequested) Fail("预览加载失败，点击查看原图"); };
                    picture.Source = bitmap; bitmap.UriSource = uri;
                }
                else if (media.State is MediaState.OnDemand or MediaState.Pending or MediaState.Stored)
                {
                    // 预览还没生成：请服务端准备，转圈等 mediaReady / chat_pts 推送（消息版本变了会换一个新视图），不轮询。
                    Busy(true);
                    var key = (message.ChatId, message.Seq, media.Ord);
                    if (!requestedPreviews.Add(key)) return;
                    try
                    {
                        var request = new RequestMediaRequest();
                        request.Refs.Add(new MediaRef { ChatId = message.ChatId, Seq = message.Seq, Ord = media.Ord });
                        await SessionFor(currentApi).RequestMediaAsync(request, ct);
                    }
                    catch { requestedPreviews.Remove(key); throw; }
                }
                else Fail(MediaPresentation.StateText(media.State));
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { if (!ct.IsCancellationRequested) Fail(error.Message); }
        };
        button.Unloaded += (_, _) => { load?.Cancel(); load?.Dispose(); load = null; started = false; };
        return button;
    }
}
