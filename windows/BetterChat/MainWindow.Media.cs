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

    private FrameworkElement MediaPreview(Message message, Segment segment, MediaInfo media, string label)
    {
        var owner = runtime;
        var ownerToken = pageTask?.Token ?? lifetime.Token;
        bool visual = segment.Image is not null || segment.Video is not null || segment.MarketFace is not null;
        var panel = new StackPanel { Spacing = 8 };
        var status = Text(MediaPresentation.StateText(media.State), 12);
        var picture = new Image { MaxWidth = 300, MaxHeight = 260, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed };
        if (visual)
        {
            double width = media.Width > 0 ? Math.Min(300, media.Width) : 240;
            double height = media.Width > 0 && media.Height > 0 ? Math.Min(260, width * media.Height / media.Width) : 180;
            picture.Width = width; picture.Height = height; picture.Visibility = Visibility.Visible;
            panel.Children.Add(picture);
        }
        panel.Children.Add(Text(label)); panel.Children.Add(status);
        var button = new Button { Content = panel, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(8), MaxWidth = 320 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        bool opening = false;
        button.Click += async (_, _) => await Guard(async () =>
        {
            if (opening || owner is null || runtime != owner || ownerToken.IsCancellationRequested) return;
            opening = true; button.IsEnabled = false; status.Text = "正在准备媒体…";
            try { await ShowMedia(message, media, label); }
            finally
            {
                opening = false;
                if (!ownerToken.IsCancellationRequested && runtime == owner)
                { button.IsEnabled = true; status.Text = "点击查看 / 重试"; }
            }
        });
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
                    var uri = await PreviewUri(currentApi, hash, ct);
                    ct.ThrowIfCancellationRequested();
                    if (api != currentApi) return;
                    var bitmap = new BitmapImage { DecodePixelWidth = 600 };
                    bitmap.ImageOpened += (_, _) => { if (!ct.IsCancellationRequested) { picture.Visibility = Visibility.Visible; status.Text = media.State == MediaState.Purged ? "原件已清理" : "点击查看"; } };
                    bitmap.ImageFailed += (_, _) => { if (!ct.IsCancellationRequested) status.Text = "预览加载失败，点击查看"; };
                    picture.Source = bitmap; bitmap.UriSource = uri;
                }
                else if (media.State is MediaState.OnDemand or MediaState.Pending or MediaState.Stored)
                {
                    var key = (message.ChatId, message.Seq, media.Ord);
                    if (!requestedPreviews.Add(key)) return;
                    try
                    {
                        var request = new RequestMediaRequest();
                        request.Refs.Add(new MediaRef { ChatId = message.ChatId, Seq = message.Seq, Ord = media.Ord });
                        await SessionFor(currentApi).RequestMediaAsync(request, ct);
                        ct.ThrowIfCancellationRequested(); status.Text = "正在准备预览…";
                    }
                    catch { requestedPreviews.Remove(key); throw; }
                    // 下载结果经 chat_pts / mediaReady 推送，无需轮询。
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception) { if (!ct.IsCancellationRequested) status.Text = "预览暂不可用，点击查看"; }
        };
        button.Unloaded += (_, _) => { load?.Cancel(); load?.Dispose(); load = null; started = false; };
        return button;
    }
}
