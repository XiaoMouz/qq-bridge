using BetterChat.Application;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Qqbridge.V1;
using Windows.System;

namespace BetterChat;

// 外壳：NavigationView 分区、TitleBar 返回 / 展开导航、右栏页面栈、未读角标、三档自适应布局、列表宽度拖动、会话右键菜单。
public sealed partial class MainWindow
{
    private enum ShellLayout { Wide, Medium, Narrow }
    // 断点和 Fluent 的窗口尺寸类一致：<640 一栏，640–1008 两栏（列表收窄），≥1008 三栏。
    private const double NarrowBreakpoint = 640, WideBreakpoint = 1008, MediumListWidth = 280;
    private ShellLayout layout = ShellLayout.Wide;
    private double listPaneWidth = AppearanceSettings.Load().ListPaneWidth;

    private void InitializeShell()
    {
        navigator.PropertyChanged += (_, _) => { ApplyAdaptiveLayout(); UpdateShellChrome(); };
        Workspace.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => UpdateShellChrome());
        Root.SizeChanged += (_, _) => ApplyAdaptiveLayout();
        UpdateThemeKey();
        Root.ActualThemeChanged += (_, _) => ThemeChanged();
        // 系统高对比度开关不会触发 ActualThemeChanged；AccessibilitySettings.HighContrastChanged 在桌面应用里订阅会直接失败
        // （0x80070490，依赖 CoreWindow，2026-10-19 实测启动崩溃），改成窗口每次激活时重新检查一次。
        Activated += (_, _) => ThemeChanged();
        ApplyAdaptiveLayout();
        // 返回：Alt+←、键盘 / 鼠标的返回键，和 TitleBar 的返回按钮一致。
        foreach (var (key, modifiers) in new[] { (VirtualKey.Left, VirtualKeyModifiers.Menu), (VirtualKey.GoBack, VirtualKeyModifiers.None) })
        {
            var back = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            back.Invoked += (sender, e) => { if (CanNavigateBack) { e.Handled = true; _ = Guard(GoBack); } };
            Root.KeyboardAccelerators.Add(back);
        }
        var find = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        find.Invoked += (sender, e) => { if (selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible) { e.Handled = true; OpenChatSearch(); } };
        Root.KeyboardAccelerators.Add(find);
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((sender, e) =>
        {
            if (!e.GetCurrentPoint(Root).Properties.IsXButton1Pressed || !CanNavigateBack) return;
            e.Handled = true; _ = Guard(GoBack);
        }), true);
    }

    // 一栏模式下打开了详情时，即使栈空也能返回列表。
    private bool CanNavigateBack => Workspace.Visibility == Visibility.Visible
        && (navigator.CanGoBack || (layout == ShellLayout.Narrow && navigator.ShowsDetail));

    private void UpdateShellChrome()
    {
        bool shell = Workspace.Visibility == Visibility.Visible;
        AppTitleBar.IsBackButtonVisible = CanNavigateBack;
        AppTitleBar.IsPaneToggleButtonVisible = shell;
        if (!shell) Nav.IsPaneOpen = false;
    }

    private void ApplyAdaptiveLayout()
    {
        double width = Root.ActualWidth;
        if (width <= 0) return;
        layout = width < NarrowBreakpoint ? ShellLayout.Narrow : width < WideBreakpoint ? ShellLayout.Medium : ShellLayout.Wide;
        bool narrow = layout == ShellLayout.Narrow;
        // 一栏时导航收进标题栏的汉堡按钮里，给内容让出 48 像素。
        Nav.PaneDisplayMode = narrow ? NavigationViewPaneDisplayMode.LeftMinimal : NavigationViewPaneDisplayMode.LeftCompact;
        ListSplitter.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        if (narrow)
        {
            bool detail = navigator.ShowsDetail;
            ListPane.Visibility = detail ? Visibility.Collapsed : Visibility.Visible;
            DetailPane.Visibility = detail ? Visibility.Visible : Visibility.Collapsed;
            ListPane.BorderThickness = new Thickness(0);
            ListColumn.MinWidth = 0; ListColumn.MaxWidth = double.PositiveInfinity;
            // 两列只留一列占满；右列不清零的话列表只拿到一半宽（2026-10-17 实测）。
            ListColumn.Width = detail ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
            DetailColumn.Width = detail ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        }
        else
        {
            ListPane.Visibility = DetailPane.Visibility = Visibility.Visible;
            ListPane.BorderThickness = new Thickness(0, 0, 1, 0);
            ListColumn.MinWidth = AppearanceSettings.MinListPaneWidth; ListColumn.MaxWidth = AppearanceSettings.MaxListPaneWidth;
            ListColumn.Width = new GridLength(layout == ShellLayout.Medium ? Math.Min(listPaneWidth, MediumListWidth) : listPaneWidth);
            DetailColumn.Width = new GridLength(1, GridUnitType.Star);
        }
        UpdateShellChrome();
    }

    private void ListSplitterDelta(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        listPaneWidth = Math.Clamp(ListColumn.ActualWidth + e.Delta.Translation.X, AppearanceSettings.MinListPaneWidth, AppearanceSettings.MaxListPaneWidth);
        ListColumn.Width = new GridLength(listPaneWidth);
    }
    private void ListSplitterCompleted(object sender, ManipulationCompletedRoutedEventArgs e) => SaveListPaneWidth();
    private void ListSplitterReset(object sender, DoubleTappedRoutedEventArgs e)
    {
        listPaneWidth = AppearanceSettings.DefaultListPaneWidth; ApplyAdaptiveLayout(); SaveListPaneWidth();
    }
    private void SaveListPaneWidth()
    {
        try { (AppearanceSettings.Load() with { ListPaneWidth = listPaneWidth }).Save(); }
        catch (IOException) { /* 宽度只是偏好，写不进去下次用默认值。 */ }
        catch (UnauthorizedAccessException) { }
    }

    private static string ChatKey(long chat) => "chat:" + chat;
    private static string ProfileKey(Peer peer, long viaGroup = 0) => $"profile:{peer.Kind}:{peer.PeerId}:{viaGroup}";
    private static string SettingKey(string name) => "setting:" + name;
    private static string GroupKey(Peer group, string title, string folder = "") => $"group:{group.PeerId}:{title}:{folder}";

    // 根导航：左侧导航、列表选中、点通知。清空返回栈。
    private Task GoRoot(string key, Func<Task> show) => navigator.ResetAsync(new(key, show));
    // 分区首页：也是根导航，但窄窗口里不把列表挤掉。
    private Task GoLanding(string key, Func<Task> show) => navigator.ResetAsync(new(key, show) { Landing = true });
    // 右栏里的下钻：入栈，返回键能回来；同一个 Key 只替换当前页（刷新、重试）。
    private Task Go(string key, Func<Task> show) => navigator.NavigateAsync(new(key, show));
    private Task Go(string key, Action show) => navigator.NavigateAsync(new(key, () => { show(); return Task.CompletedTask; }));

    private async Task GoBack()
    {
        if (Workspace.Visibility != Visibility.Visible) return;
        if (navigator.CanGoBack) { await navigator.GoBackAsync(); return; }
        if (layout == ShellLayout.Narrow && navigator.ShowsDetail) await ReturnToList();
    }

    // 一栏模式从详情回到列表：关掉当前页并取消列表选中，否则再点同一行不会触发 SelectionChanged。
    private async Task ReturnToList()
    {
        await SaveDraft();
        NewPage(); selectedChat = 0;
        rendering = true; Items.SelectedItem = null; rendering = false;
        navigator.Clear();
        Detail(section == "messages" ? "选择一个会话" : SectionTitle.Text, "");
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

    // 调试入口（同 iOS 的 -debugJump chatId:seq）：登录后直接打开某个会话、定位到某条消息附近。
    // 验收时用它代替按列表位置点或模拟滚动（UI 自动化的滚动对这个 ListView 不生效，2026-10-17 实测）。只处理一次。
    private bool debugJumpDone;
    private void RunDebugJump()
    {
        if (debugJumpDone) return;
        debugJumpDone = true;
        var args = Environment.GetCommandLineArgs();
        // -debugSearch <关键词>：直接做一次全局搜索（UI 自动化点不到搜索框的提交按钮，也不能按回车）。
        int search = Array.IndexOf(args, "-debugSearch");
        if (search >= 0 && search + 1 < args.Length) { string query = args[search + 1]; _ = Guard(() => StartSearch(query)); return; }
        int at = Array.IndexOf(args, "-debugJump");
        if (at < 0 || at + 1 >= args.Length) return;
        var parts = args[at + 1].Split(':');
        if (parts.Length != 2 || !long.TryParse(parts[0], out long chat) || !long.TryParse(parts[1], out long seq) || chat <= 0) return;
        // -debugAttach <文件路径>：打开会话后直接放进附件预览条（不经过系统文件选择框），用来验收上传和发送。
        int attach = Array.IndexOf(args, "-debugAttach");
        string? file = attach >= 0 && attach + 1 < args.Length ? args[attach + 1] : null;
        _ = Guard(async () =>
        {
            await GoRoot(ChatKey(chat), () => OpenChat(chat, seq > 0 ? seq : null));
            if (file is not null && selectedChat == chat) AddAttachments([await Windows.Storage.StorageFile.GetFileFromPathAsync(file)]);
        });
    }

    private void UpdateUnreadBadge()
    {
        int count = runtime?.Dialogs.Items.Sum(row => row.BadgeCount) ?? 0;
        if (count > 0) UnreadBadge.Value = count;
        UnreadBadge.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(MessagesNavItem, count > 0 ? $"消息（{count} 条未读）" : "消息");
    }

    // 会话行右键（或 Shift+F10 / 菜单键）：和 iOS 长按菜单相同的四项。结果以同步回来的会话为准，这里不改本地状态。
    private void ListRowContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if (sender is not FrameworkElement { DataContext: ListEntry { Value: Dialog row } } element || runtime is not { } session) return;
        var d = dialogIndex.GetValueOrDefault(row.ChatId) ?? row;
        args.Handled = true;
        var menu = new MenuFlyout();
        void Item(string text, string glyph, Func<CancellationToken, Task> run)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += async (_, _) => await Guard(async () =>
            {
                if (runtime != session) return;
                await run(lifetime.Token);
            });
            menu.Items.Add(item);
        }
        if (d.UnreadCount > 0)
            Item("标为已读", "", ct => session.MarkReadAsync(new() { ChatId = d.ChatId, MaxSeq = d.TopSeq }, ct));
        Item(d.Pinned ? "取消置顶" : "置顶", d.Pinned ? "" : "", ct => session.SetPinnedAsync(new() { ChatId = d.ChatId, Pinned = !d.Pinned }, ct));
        Item(DialogListFormat.IsMuted(d) ? "接收并提醒" : "接收不提醒", DialogListFormat.IsMuted(d) ? "" : "",
            ct => session.SetNotifyPolicyAsync(new() { ChatId = d.ChatId, Policy = DialogListFormat.ToggleMutedPolicy(d) }, ct));
        if (d.Scene == Scene.Group)
            Item(DialogListFormat.IsArchived(d) ? "移出群助手" : "收进群助手", "",
                ct => session.SetNotifyPolicyAsync(new() { ChatId = d.ChatId, Policy = DialogListFormat.ToggleArchivedPolicy(d) }, ct));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item("会话与通知设置", "", _ => GoRoot("prefs:" + d.ChatId, () => ShowDialogPreferences(d.ChatId)));
        if (args.TryGetPosition(element, out var point)) menu.ShowAt(element, new FlyoutShowOptions { Position = point });
        else menu.ShowAt(element);
    }
}
