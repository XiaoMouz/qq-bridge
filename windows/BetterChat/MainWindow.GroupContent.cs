using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

// 群公告、群精华：每条一张卡片，页头是发送者头像、名字和时间。
public sealed partial class MainWindow
{
    private FrameworkElement PublicGroupImage(string address, CancellationToken ct)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http") || uri.UserInfo.Length > 0)
            return new TextBlock { Text = "图片链接不可用", Style = Res<Style>("SecondaryCaptionTextBlockStyle") };
        var picture = new Image { MaxWidth = 320, MaxHeight = 240, Stretch = Stretch.Uniform };
        var frame = new Grid { CornerRadius = new CornerRadius(6), MinWidth = 120, MinHeight = 80, Background = Brush("SubtleFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Left };
        frame.Children.Add(picture);
        var button = new Button { Content = frame, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "查看群图片原图");
        ToolTipService.SetToolTip(button, "查看原图");
        button.Click += async (_, _) => await Guard(async () =>
        {
            ct.ThrowIfCancellationRequested();
            await DialogBox("群图片", new Image { Source = new BitmapImage(uri), MaxWidth = 900, MaxHeight = 650, Stretch = Stretch.Uniform });
        });
        button.Loaded += (_, _) =>
        {
            if (ct.IsCancellationRequested) return;
            var bitmap = new BitmapImage { DecodePixelWidth = 640 };
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
        foreach (string url in notice.ImageUrls) body.Children.Add(PublicGroupImage(url, ct));
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
            foreach (string url in essence.ImageUrls) body.Children.Add(PublicGroupImage(url, ct));
        }
        return card;
    }
}
