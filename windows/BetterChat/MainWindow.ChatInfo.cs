using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

// 会话资料栏（同 Mac 的右侧检查器，a68e612 / 81e2017）：窗口够宽时放在聊天右边、聊天让出宽度，内容跟着当前会话换；
// 开关记在 AppearanceSettings 里跨启动保留。不够宽时不显示，「查看资料」退回在右栏推入资料页；变宽后按原来的开关恢复。
// 资料里的群成员、群公告等仍在右栏推入（盖掉聊天、资料栏随之收起，返回后恢复），不在资料栏里套一层导航。
public sealed partial class MainWindow
{
    // 三栏（≥1008）里再放 320 的资料栏，聊天至少还剩 500 多（导航 48 + 列表 320 + 边距）。
    private const double ChatInfoBreakpoint = 1280, ChatInfoWidth = 320;
    private bool chatInfoOpen = AppearanceSettings.Load().ChatInfoOpen;
    private long chatInfoChat;
    private IDisposable? chatInfoPage;
    private CancellationTokenSource? chatInfoTask;

    private bool ChatInfoFits => layout == ShellLayout.Wide && Root.ActualWidth >= ChatInfoBreakpoint;

    private void InitializeChatInfo()
    {
        // 资料栏的标题行和聊天标题行（标题 + 副标题）等高，两条分隔线才对齐。
        DetailHeader.SizeChanged += (_, e) => InfoHeader.Height = e.NewSize.Height;
        // 不在 OpenChat / Detail 里逐处调用，跟着界面状态走：聊天面板显隐（打开会话、推入别的页面）、
        // 消息列表清空重填（聊天之间切换，面板一直可见）、会话标题变化（会话列表晚到，资料这时才查得到）、退出登录。
        ChatPanel.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => UpdateChatInfo());
        Workspace.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => UpdateChatInfo());
        ContentTitle.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => UpdateChatInfo());
        Messages.Items.VectorChanged += (_, _) => { if (chatInfoChat != selectedChat) UpdateChatInfo(); };
    }

    private Peer? ChatPeer(long chat) =>
        dialogIndex.GetValueOrDefault(chat) is { } d ? peerIndex.GetValueOrDefault((d.PeerId, d.Scene == Scene.Group)) : null;

    private void ChatInfoClicked(object sender, RoutedEventArgs e) => _ = Guard(ToggleChatInfo);
    private void CloseChatInfoClicked(object sender, RoutedEventArgs e) => SetChatInfoOpen(false);

    // 资料按钮和「会话选项 → 查看资料」：放得下资料栏就开关它，否则推入资料页。
    private Task ToggleChatInfo()
    {
        if (ChatInfoFits) { SetChatInfoOpen(!chatInfoOpen); return Task.CompletedTask; }
        return ChatPeer(selectedChat) is { } p ? Go(ProfileKey(p), () => ShowProfile(p)) : Task.CompletedTask;
    }

    private void SetChatInfoOpen(bool open)
    {
        chatInfoOpen = open;
        try { (AppearanceSettings.Load() with { ChatInfoOpen = open }).Save(); }
        catch (IOException) { /* 开关只是偏好，写不进去下次按关闭处理。 */ }
        catch (UnauthorizedAccessException) { }
        UpdateChatInfo();
    }

    // 布局变化、打开 / 离开会话、会话列表刷新后调用：决定显不显示，换了会话就重画。
    private void UpdateChatInfo()
    {
        var peer = chatInfoOpen && ChatInfoFits && selectedChat != 0 && Workspace.Visibility == Visibility.Visible
            && ChatPanel.Visibility == Visibility.Visible ? ChatPeer(selectedChat) : null;
        double width = peer is null ? 0 : ChatInfoWidth;
        if (InfoColumn.Width.Value != width) InfoColumn.Width = new GridLength(width);
        InfoPane.Visibility = peer is null ? Visibility.Collapsed : Visibility.Visible;
        if (peer is null) { if (chatInfoChat != 0 || chatInfoPage is not null) CloseChatInfo(); return; }
        if (chatInfoChat != selectedChat) RenderChatInfo(peer, selectedChat);
    }

    private void RenderChatInfo(Peer peer, long chat)
    {
        CloseChatInfo();
        chatInfoChat = chat;
        chatInfoTask = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        InfoTitle.Text = peer.Kind == PeerKind.Group ? "群资料" : "资料";
        ShowProfile(peer, 0, InfoDetails);
    }

    private void CloseChatInfo()
    {
        chatInfoPage?.Dispose(); chatInfoPage = null;
        chatInfoTask?.Cancel(); chatInfoTask?.Dispose(); chatInfoTask = null;
        chatInfoChat = 0; InfoDetails.Children.Clear();
    }

    // 资料栏只有 320 宽：头像、名字、号码上下排、居中（右栏资料页的 Hero 是左右排）。
    private static FrameworkElement StackedHero(UIElement picture, string title, params string[] lines)
    {
        var stack = new StackPanel { Spacing = 4, Margin = new Thickness(0, 4, 0, 8), HorizontalAlignment = HorizontalAlignment.Stretch };
        if (picture is FrameworkElement element) { element.HorizontalAlignment = HorizontalAlignment.Center; element.Margin = new Thickness(0, 0, 0, 8); }
        stack.Children.Add(picture);
        stack.Children.Add(new TextBlock { Text = title, Style = Res<Style>("SubtitleTextBlockStyle"), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, IsTextSelectionEnabled = true });
        foreach (var line in lines.Where(l => l.Length > 0))
            stack.Children.Add(new TextBlock { Text = line, Style = Res<Style>("BodyTextBlockStyle"), Foreground = Brush("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, IsTextSelectionEnabled = true });
        return stack;
    }
}
