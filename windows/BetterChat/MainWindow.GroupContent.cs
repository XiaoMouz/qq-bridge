using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private FrameworkElement PublicGroupImage(string address, CancellationToken ct)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http") || uri.UserInfo.Length > 0)
            return Text("图片链接不可用", 12);
        var status = Text("加载图片…", 12);
        var picture = new Image { MaxWidth = 320, MaxHeight = 240, Stretch = Stretch.Uniform };
        var panel = new StackPanel { Spacing = 4 }; panel.Children.Add(picture); panel.Children.Add(status);
        var button = ActionButton("查看原图", async () =>
        {
            ct.ThrowIfCancellationRequested();
            await DialogBox("群图片", new Image { Source = new BitmapImage(uri), MaxWidth = 900, MaxHeight = 650, Stretch = Stretch.Uniform });
        });
        button.Content = panel;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "查看群图片原图");
        button.Loaded += (_, _) =>
        {
            if (ct.IsCancellationRequested) return;
            var bitmap = new BitmapImage { DecodePixelWidth = 640 };
            bitmap.ImageOpened += (_, _) => { if (!ct.IsCancellationRequested) status.Text = "查看原图"; };
            bitmap.ImageFailed += (_, _) => { if (!ct.IsCancellationRequested) status.Text = "图片加载失败，点击重试"; };
            picture.Source = bitmap; bitmap.UriSource = uri;
        };
        button.Unloaded += (_, _) => picture.Source = null;
        return button;
    }

    private FrameworkElement GroupNoticeView(GroupNotice notice, CancellationToken ct)
    {
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(0, 8, 0, 16) };
        panel.Children.Add(Text((notice.Pinned ? "置顶 · " : "") + notice.SenderName, 18));
        panel.Children.Add(Text(notice.Text));
        foreach (string url in notice.ImageUrls) panel.Children.Add(PublicGroupImage(url, ct));
        panel.Children.Add(Text($"{notice.ReadCount} 人已读" + (notice.ConfirmRequired ? notice.ReadByMe ? " · 已确认" : " · 需要确认" : ""), 12));
        return panel;
    }

    private FrameworkElement GroupEssenceView(GroupEssence essence, CancellationToken ct)
    {
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(0, 8, 0, 16) };
        panel.Children.Add(Text(essence.SenderName + (essence.OperatorName.Length > 0 ? " · " + essence.OperatorName + " 设为精华" : ""), 18));
        if (essence.Message is { ChatId: > 0, Seq: > 0 } message)
        {
            // 资料页没有正在编辑的会话，不能复用聊天气泡中修改 selectedChat 草稿的回复菜单。
            panel.Children.Add(MessageView(message.Clone(), includeActions: false));
            panel.Children.Add(ActionButton("定位原消息", async () => { ct.ThrowIfCancellationRequested(); await Go(ChatKey(message.ChatId), () => OpenChat(message.ChatId, message.Seq)); }));
        }
        else
        {
            panel.Children.Add(Text(essence.Text));
            foreach (string url in essence.ImageUrls) panel.Children.Add(PublicGroupImage(url, ct));
        }
        return panel;
    }
}
