using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

// 群公告、群精华：每条一张卡片，页头是发送者头像、名字和时间。
public sealed partial class MainWindow
{
    private static Uri? PublicImageUri(string address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" && uri.UserInfo.Length == 0 ? uri : null;

    // 一组公开图片排成可换行的缩略图，点开进查看器，同一条公告 / 精华里的图片左右切换。
    private FrameworkElement PublicGroupImages(IEnumerable<string> addresses, string sender, long time, CancellationToken ct)
    {
        var images = addresses.Select(PublicImageUri).OfType<Uri>().ToList();
        // 一张按原比例显示；多张排成 120 见方的格子（同 iOS 公告的九宫格），格子尺寸固定才能换行对齐。
        var panel = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = images.Count == 1 ? double.NaN : 128, ItemHeight = images.Count == 1 ? double.NaN : 128 };
        for (int i = 0; i < images.Count; i++) panel.Children.Add(PublicGroupImage(images, i, sender, time, ct));
        return panel;
    }

    private FrameworkElement PublicGroupImage(IReadOnlyList<Uri> images, int index, string sender, long time, CancellationToken ct)
    {
        var uri = images[index];
        bool single = images.Count == 1;
        var picture = single ? new Image { MaxWidth = 320, MaxHeight = 240, Stretch = Stretch.Uniform } : new Image { Width = 120, Height = 120, Stretch = Stretch.UniformToFill };
        var frame = new Grid { CornerRadius = Res<object>("ControlCornerRadius") is CornerRadius r ? r : new CornerRadius(4), MinWidth = 120, MinHeight = single ? 80 : 120, Background = Brush("SubtleFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Left };
        frame.Children.Add(picture);
        var button = new Button { Content = frame, Padding = new Thickness(0), Margin = new Thickness(0, 0, 8, 8), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "查看群图片原图");
        ToolTipService.SetToolTip(button, "查看原图");
        button.Click += async (_, _) => await Guard(async () =>
        {
            ct.ThrowIfCancellationRequested();
            await OpenPublicImages(images, index, sender, time);
        });
        button.Loaded += (_, _) =>
        {
            if (ct.IsCancellationRequested) return;
            var bitmap = new BitmapImage { DecodePixelWidth = single ? 640 : 240 };
            bitmap.ImageOpened += (_, _) => { if (!ct.IsCancellationRequested) frame.Background = null; };
            picture.Source = bitmap; bitmap.UriSource = uri;
        };
        button.Unloaded += (_, _) => picture.Source = null;
        return button;
    }

    // 卡片外框和页头：头像、名字、时间，右边可选一个状态标签。
    private (Border Card, StackPanel Body) ContentCard(long senderId, string senderName, long time, FrameworkElement? badge = null)
    {
        var header = new Grid { ColumnSpacing = 10 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var avatar = new PersonPicture { Width = 32, Height = 32, DisplayName = senderName, Tag = senderId };
        if (senderId > 0) avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, senderId);
        header.Children.Add(avatar);
        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(new TextBlock { Text = senderName.Length > 0 ? senderName : senderId.ToString(), Style = Res<Style>("BodyStrongTextBlockStyle"), TextTrimming = TextTrimming.CharacterEllipsis });
        if (time > 0) names.Children.Add(new TextBlock { Text = ChatPresentationTime(time), Style = Res<Style>("SecondaryCaptionTextBlockStyle") });
        Grid.SetColumn(names, 1); header.Children.Add(names);
        if (badge is not null) { Grid.SetColumn(badge, 2); header.Children.Add(badge); }
        var body = new StackPanel { Spacing = 10 };
        body.Children.Add(header);
        var card = new Border
        {
            Child = body, Padding = new Thickness(16), CornerRadius = Res<object>("OverlayCornerRadius") is CornerRadius r ? r : new CornerRadius(8),
            Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1)
        };
        return (card, body);
    }
    private static string ChatPresentationTime(long unix) => BetterChat.Application.ChatPresentation.TimeHeader(unix, DateTimeOffset.Now, TimeZoneInfo.Local);

    private FrameworkElement GroupNoticeView(GroupNotice notice, CancellationToken ct)
    {
        var (card, body) = ContentCard(notice.SenderId, notice.SenderName, notice.Time, notice.Pinned ? StatusPill("置顶", Health.Warning) : null);
        body.Children.Add(new TextBlock { Text = notice.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        if (notice.ImageUrls.Count > 0) body.Children.Add(PublicGroupImages(notice.ImageUrls, notice.SenderName, notice.Time, ct));
        string footer = $"{notice.ReadCount} 人已读" + (notice.ConfirmRequired ? notice.ReadByMe ? " · 我已确认" : " · 需要确认" : "");
        body.Children.Add(new TextBlock { Text = footer, Style = Res<Style>("SecondaryCaptionTextBlockStyle") });
        return card;
    }

    private FrameworkElement GroupEssenceView(GroupEssence essence, CancellationToken ct)
    {
        var (card, body) = ContentCard(essence.SenderId, essence.SenderName, essence.Time);
        if (essence.OperatorName.Length > 0)
            body.Children.Add(new TextBlock { Text = essence.OperatorName + " 设为精华", Style = Res<Style>("SecondaryCaptionTextBlockStyle") });
        if (essence.Message is { ChatId: > 0, Seq: > 0 } message)
        {
            // 资料页没有正在编辑的会话，不能复用聊天气泡中修改 selectedChat 草稿的回复菜单。
            body.Children.Add(MessageView(message.Clone(), includeActions: false));
            var locate = new HyperlinkButton { Content = "定位原消息", Padding = new Thickness(0) };
            locate.Click += async (_, _) => await Guard(async () => { ct.ThrowIfCancellationRequested(); await Go(ChatKey(message.ChatId), () => OpenChat(message.ChatId, message.Seq)); });
            body.Children.Add(locate);
        }
        else
        {
            body.Children.Add(new TextBlock { Text = essence.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            if (essence.ImageUrls.Count > 0) body.Children.Add(PublicGroupImages(essence.ImageUrls, essence.SenderName, essence.Time, ct));
        }
        return card;
    }
}
