using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Qqbridge.V1;
using Windows.System;

namespace BetterChat;

// 外壳：NavigationView 分区、TitleBar 返回 / 展开导航、右栏页面栈、未读角标。
public sealed partial class MainWindow
{
    private void InitializeShell()
    {
        navigator.PropertyChanged += (_, _) => UpdateShellChrome();
        Workspace.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => UpdateShellChrome());
        UpdateShellChrome();
        // 返回：Alt+←、键盘 / 鼠标的返回键，和 TitleBar 的返回按钮一致。
        foreach (var (key, modifiers) in new[] { (VirtualKey.Left, VirtualKeyModifiers.Menu), (VirtualKey.GoBack, VirtualKeyModifiers.None) })
        {
            var back = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            back.Invoked += (sender, e) => { if (navigator.CanGoBack && Workspace.Visibility == Visibility.Visible) { e.Handled = true; _ = Guard(GoBack); } };
            Root.KeyboardAccelerators.Add(back);
        }
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((sender, e) =>
        {
            if (!e.GetCurrentPoint(Root).Properties.IsXButton1Pressed || !navigator.CanGoBack) return;
            e.Handled = true; _ = Guard(GoBack);
        }), true);
    }

    private void UpdateShellChrome()
    {
        bool shell = Workspace.Visibility == Visibility.Visible;
        AppTitleBar.IsBackButtonVisible = shell && navigator.CanGoBack;
        AppTitleBar.IsPaneToggleButtonVisible = shell;
        if (!shell) Nav.IsPaneOpen = false;
    }

    private static string ChatKey(long chat) => "chat:" + chat;
    private static string ProfileKey(Peer peer, long viaGroup = 0) => $"profile:{peer.Kind}:{peer.PeerId}:{viaGroup}";
    private static string SettingKey(string name) => "setting:" + name;
    private static string GroupKey(Peer group, string title, string folder = "") => $"group:{group.PeerId}:{title}:{folder}";

    // 根导航：左侧导航、列表选中、点通知。清空返回栈。
    private Task GoRoot(string key, Func<Task> show) => navigator.ResetAsync(new(key, show));
    // 右栏里的下钻：入栈，返回键能回来；同一个 Key 只替换当前页（刷新、重试）。
    private Task Go(string key, Func<Task> show) => navigator.NavigateAsync(new(key, show));
    private Task Go(string key, Action show) => navigator.NavigateAsync(new(key, () => { show(); return Task.CompletedTask; }));

    private async Task GoBack()
    {
        if (Workspace.Visibility != Visibility.Visible) return;
        await navigator.GoBackAsync();
    }

    private void TitleBarBackRequested(TitleBar sender, object args) => _ = Guard(GoBack);
    private void TitleBarPaneToggleRequested(TitleBar sender, object args) => Nav.IsPaneOpen = !Nav.IsPaneOpen;
    // 紧凑栏只放得下头像；展开时和导航项一样显示文字。
    private void NavPaneOpening(NavigationView sender, object args) => AccountName.Visibility = Visibility.Visible;
    private void NavPaneClosing(NavigationView sender, NavigationViewPaneClosingEventArgs args) => AccountName.Visibility = Visibility.Collapsed;

    private void AccountClicked(object sender, RoutedEventArgs e)
    {
        // 已经在设置分区时选中项不变、不会触发 NavChanged，直接打开账号页。
        if (ReferenceEquals(Nav.SelectedItem, SettingsNavItem))
            _ = Guard(() => GoRoot(SettingKey("连接与账号"), () => { NewPage(); return ShowSetting("连接与账号"); }));
        else Nav.SelectedItem = SettingsNavItem;
    }

    private void UpdateUnreadBadge()
    {
        int count = runtime?.Dialogs.Items.Sum(row => row.BadgeCount) ?? 0;
        if (count > 0) UnreadBadge.Value = count;
        UnreadBadge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(MessagesNavItem, count > 0 ? $"消息（{count} 条未读）" : "消息");
    }
}
