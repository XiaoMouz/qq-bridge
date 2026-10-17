using BetterChat.Application;
using BetterChat.Core;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private void ShowConnection()
    {
        if (api is not null)
        {
            Detail("连接与账号", "当前登录的 QQ Bridge");
            Details.Children.Add(Text(AccountAvatar.DisplayName, 24));
            Details.Children.Add(Text("服务器：" + api.Transport.BaseUri.Host));
            Details.Children.Add(Text(connectionStatus, 12));
            Details.Children.Add(ActionButton("查看服务端 QQ 登录状态", () => Go("qq-login", ShowQqLogin)));
            Details.Children.Add(Text(notifications?.Error is { } notificationError
                ? "Windows 通知不可用：" + notificationError : "Windows 通知：运行期间接收新消息", 12));
            Details.Children.Add(ActionButton("退出登录", async () =>
            {
                var session = runtime; if (session is null) return;
                var result = await BetterChat.Application.LogoutCoordinator.RunAsync(
                    () => PersistUnsavedDrafts(session), SessionSettings.Clear,
                    ct => session.Api.LogoutAsync(new(), ct), Disconnect);
                lifetime = new();
                connectionStatus = "尚未连接"; RefreshList(); ShowWelcome();
                if (!result.RemoteRevoked)
                {
                    Notice.Severity = InfoBarSeverity.Warning;
                    Notice.Message = "已退出本机账号。服务端注销未确认，可在其他设备的设备管理中撤销此设备。"; Notice.IsOpen = true;
                }
            }));
            return;
        }
        if (api is null)
        {
            Workspace.Visibility = Visibility.Collapsed; Onboarding.Visibility = Visibility.Visible;
            AccountButton.Visibility = Visibility.Collapsed;
            OnboardingSubtitle.Text = "登录你的 QQ Bridge";
            OnboardingContent.Children.Clear();
        }
        else Detail("连接与账号", "连接你自己的 QQ Bridge 服务器");
        var form = api is null ? OnboardingContent : Details;
        var server = new TextBox { Header = "服务器地址", PlaceholderText = "https://your-server.example", Text = api?.Transport.BaseUri.AbsoluteUri ?? SessionSettings.Load()?.Server ?? "" };
        var username = new TextBox { Header = "用户名", Text = "owner", PlaceholderText = "QQ Bridge 用户名" };
        var password = new PasswordBox { Header = "密码", PlaceholderText = "QQ Bridge 账号密码" };
        form.Children.Add(server); form.Children.Add(username); form.Children.Add(password);
        form.Children.Add(Text("使用 QQ Bridge 服务端账号登录。密码不会保存到本机。", 12));
        var login = new Button { Content = "登录", Style = (Style)Microsoft.UI.Xaml.Application.Current.Resources["AccentButtonStyle"] };
        bool busy = false;
        async Task SignIn()
        {
            if (busy) return;
            busy = true; login.IsEnabled = false; server.IsEnabled = username.IsEnabled = password.IsEnabled = false;
            login.Content = "正在登录…";
            var ct = NewPage();
            await Guard(async () =>
            {
                var uri = Authentication.ServerUri(server.Text);
                using var transport = new ConnectClient(uri);
                try
                {
                    var result = await Authentication.LoginAsync(new BridgeApi(transport), username.Text, password.Password,
                        Environment.MachineName + " · Windows", ct);
                    ct.ThrowIfCancellationRequested();
                    password.Password = "";
                    await Connect(uri.AbsoluteUri, result.Token);
                }
                catch (RpcException e) when (e.Code == "unauthenticated")
                { throw new InvalidOperationException("用户名或密码不正确，请重新输入。"); }
            });
            busy = false; login.IsEnabled = true; server.IsEnabled = username.IsEnabled = password.IsEnabled = true;
            login.Content = "登录";
        }
        login.Click += async (_, _) => await SignIn();
        password.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await SignIn(); } };
        form.Children.Add(login);
    }
    private async Task ShowSetting(string name)
    {
        Detail(name);
        if (name == "连接与账号") { ShowConnection(); return; }
        if (name == "外观")
        {
            Details.Children.Add(Text("主题", 20));
            var theme = new ComboBox { ItemsSource = new[] { "跟随系统", "浅色", "深色" }, SelectedIndex = (int)Root.RequestedTheme, MinWidth = 220 };
            theme.SelectionChanged += async (_, _) => await Guard(() =>
            {
                if (theme.SelectedIndex < 0) return Task.CompletedTask;
                var value = (ElementTheme)theme.SelectedIndex;
                (AppearanceSettings.Load() with { Theme = value }).Save(); Root.RequestedTheme = value;
                return Task.CompletedTask;
            });
            Details.Children.Add(theme);
            Details.Children.Add(Text("使用 Windows 原生控件、系统强调色与 Mica 材质。支持键盘操作与高对比度主题。"));
            return;
        }
        if (name == "关于")
        {
            Details.Children.Add(Text("BetterChat", 32));
            Details.Children.Add(Text("QQ Bridge 的 Windows 原生客户端\nWinUI 3 · Fluent Design · ConnectRPC"));
            Details.Children.Add(Text("快捷键：Ctrl + K 搜索；Enter 发送；Shift + Enter 换行。右键消息可回复、复制、转发及撤回。"));
            return;
        }
        if (api is null) { Details.Children.Add(Text("请先连接服务器。")); return; }
        var ct = NewPage();
        if (name == "服务端状态") await ShowServerStatus(ct);
        else if (name == "存档完整性") await ShowArchiveStatus(ct);
        else if (name == "设备")
        {
            if (runtime is not { } deviceSession) return;
            var vm = new DevicesViewModel(deviceSession.ListDevicesAsync, deviceSession.RevokeDeviceAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
            if (!await vm.LoadAsync(ct)) { ct.ThrowIfCancellationRequested(); throw new IOException(vm.Load.Error ?? "设备加载失败。"); }
            ct.ThrowIfCancellationRequested();
            foreach (var d in vm.Items)
            {
                var panel = new StackPanel { Spacing = 8 };
                panel.Children.Add(Text(d.Name + (d.Current ? " · 当前设备" : ""), 18));
                panel.Children.Add(Text(d.Platform + " · 最近活动 " + DateTimeOffset.FromUnixTimeSeconds(d.LastSeenAt).ToLocalTime().ToString("g"), 12));
                if (!d.Current) panel.Children.Add(ActionButton("移除此设备", async () =>
                {
                    var confirm = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "移除设备？", Content = d.Name + " 将无法继续访问服务器。", PrimaryButtonText = "移除", CloseButtonText = "取消" };
                    if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                    ct.ThrowIfCancellationRequested();
                    if (runtime != deviceSession) return;
                    if (!await vm.RevokeAsync(d.Id, ct))
                    {
                        ct.ThrowIfCancellationRequested();
                        throw new IOException((vm.Revoke.Error ?? "设备移除失败。") + (vm.Revoke.OutcomeUncertain ? " 请刷新设备列表确认结果。" : ""));
                    }
                    ct.ThrowIfCancellationRequested();
                    Details.Children.Remove(panel);
                }));
                Details.Children.Add(panel);
            }
        }
        else if (name == "存储")
        {
            if (runtime is not { } storageSession) return;
            var load = new RpcOperationViewModel<GetStorageOverviewRequest, GetStorageOverviewResponse>(storageSession.GetStorageOverviewAsync, new UiDispatcher(DispatcherQueue), false); featurePage = load;
            Details.Children.Add(ActionButton("本机预览缓存", () => Go("preview-cache", ShowPreviewCache)));
            Details.Children.Add(ActionButton("全局存储策略", () => Go($"policy:{PolicyScope.Global}::", () => ShowStoragePolicy(PolicyScope.Global))));
            foreach (var scene in new[] { Scene.Friend, Scene.Group, Scene.Temp })
                Details.Children.Add(ActionButton($"{scene} 类型存储策略", () => Go($"policy:{PolicyScope.Scene}:{scene}:", () => ShowStoragePolicy(PolicyScope.Scene, scene))));
            if (!await load.ExecuteAsync(new() { Limit = 30 }, ct))
            {
                ct.ThrowIfCancellationRequested();
                if (featurePage != load || runtime != storageSession) return;
                throw new IOException(load.Error ?? "存储概览加载失败。");
            }
            ct.ThrowIfCancellationRequested();
            if (featurePage != load || runtime != storageSession) return;
            var r = load.Result!;
            Details.Children.Add(Text("已使用 " + Bytes(r.PhysicalBytes), 28));
            Details.Children.Add(Text($"去重节省 {Bytes(r.DedupSavedBytes)} · {r.BlobCount:N0} 份媒体\n热存储 {Bytes(r.HotBytes)} · 冷存储 {Bytes(r.ColdBytes)}"));
            foreach (var c in r.Categories.OrderByDescending(c => c.Bytes))
            {
                string label = $"{Category(c.Category)}    {Bytes(c.Bytes)}    {c.Count:N0} 项";
                Details.Children.Add(StorageCategories.HasChats(c.Category) ? ActionButton(label, () => Go("storage-chats:" + c.Category, () => ShowStorageChats(c.Category))) : Text(label));
            }
        }
        else if (name == "通话记录")
        {
            var r = await api.ListCallsAsync(new() { Limit = 50 }, ct); ct.ThrowIfCancellationRequested();
            if (r.Calls.Count == 0) Details.Children.Add(Text("暂无通话记录"));
            foreach (var c in r.Calls) Details.Children.Add(Text($"{(c.Incoming ? "来电" : "呼出")} · {c.PeerName}\n{DateTimeOffset.FromUnixTimeSeconds(c.InviteAt).ToLocalTime():g} · {c.Phase}"));
        }
    }
    private static string Bytes(ulong n) => n >= 1073741824 ? $"{n / 1073741824d:F1} GB" : n >= 1048576 ? $"{n / 1048576d:F1} MB" : $"{n / 1024d:F1} KB";
    private static string Category(string key) => key switch { "image" => "图片", "video" => "视频", "record" => "语音", "file" => "文件", "group_file" => "群文件", "avatar" => "头像", "sticker" => "表情", "qq_thumb" => "缩略图", "derived" => "媒体预览", _ => "其他" };

    private void ShowProfile(Peer peer, long viaGroup = 0)
    {
        if (runtime is not { } profileSession) return;
        var profileToken = pageTask?.Token ?? lifetime.Token;
        featurePage?.Dispose();
        var vm = new ContactProfileViewModel(peer, viaGroup, profileSession.GetUserProfileAsync, profileSession.GetGroupProfileAsync, profileSession.OpenChatAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        Detail(DisplayName(peer), peer.Kind == PeerKind.Group ? "群资料" : "联系人资料");
        Details.Children.Add(new PersonPicture { DisplayName = DisplayName(peer), Width = 88, Height = 88, HorizontalAlignment = HorizontalAlignment.Left });
        Details.Children.Add(Text(DisplayName(peer), 28));
        Details.Children.Add(Text((peer.Kind == PeerKind.Group ? "群号 " : "QQ ") + peer.PeerId));
        if (peer.Sign.Length > 0) Details.Children.Add(Text(peer.Sign));
        if (peer.Kind == PeerKind.Group) Details.Children.Add(Text($"{peer.MemberCount} 位成员"));
        Details.Children.Add(ActionButton("发送消息", async () =>
        {
            if (runtime != profileSession) return;
            bool opened = await vm.Open.ExecuteAsync(new(), profileToken);
            if (featurePage != vm || runtime != profileSession) return;
            if (!opened) { profileToken.ThrowIfCancellationRequested(); throw new IOException(vm.Open.Error ?? "无法打开会话。"); }
            profileToken.ThrowIfCancellationRequested();
            if (runtime == profileSession) { long target = vm.Open.Result!.ChatId; await Go(ChatKey(target), () => OpenChat(target)); }
        }));
        Details.Children.Add(ActionButton("刷新资料", async () =>
        {
            if (runtime != profileSession) return;
            bool refreshed = await vm.Refresh.ExecuteAsync(new(), profileToken);
            if (featurePage != vm || runtime != profileSession) return;
            if (!refreshed) { profileToken.ThrowIfCancellationRequested(); throw new IOException(vm.Refresh.Error ?? "资料刷新失败。"); }
            profileToken.ThrowIfCancellationRequested();
            if (runtime == profileSession) ShowProfile(vm.Refresh.Result!, viaGroup);
        }));
        if (peer.Kind == PeerKind.User && peer.IsFriend && runtime is { } contactSession)
        {
            Details.Children.Add(ActionButton("删除好友", async () =>
            {
                var ct = profileToken;
                if (runtime != contactSession || featurePage != vm || ct.IsCancellationRequested) return;
                if (!contactSession.Contacts.Directory.Friends.Any(p => p.PeerId == peer.PeerId))
                {
                    if (!await contactSession.Contacts.LoadAsync(ct: ct))
                        throw new IOException(contactSession.Contacts.Load.Error ?? "无法加载好友列表。");
                }
                ct.ThrowIfCancellationRequested();
                if (featurePage != vm || runtime != contactSession) return;
                var confirm = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "删除好友",
                    Content = $"确定删除 {DisplayName(peer)}（{peer.PeerId}）吗？", PrimaryButtonText = "删除", CloseButtonText = "取消" };
                if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                ct.ThrowIfCancellationRequested();
                if (runtime != contactSession || featurePage != vm) return;
                var operation = contactSession.Contacts.DeleteFriend;
                if (!await operation.ExecuteAsync(new(peer.PeerId), ct))
                    throw new IOException((operation.Error ?? "删除未完成。") + (operation.OutcomeUncertain ? " 服务端结果待确认，请刷新列表。" : ""));
                ct.ThrowIfCancellationRequested();
                if (runtime != contactSession || featurePage != vm) return;
                Detail("好友已删除", DisplayName(peer));
            }));
        }
        if (section == "contacts")
            Details.Children.Add(ActionButton("返回联系人分组", () => { ShowContactsOverview(); return Task.CompletedTask; }));
        if (peer.Kind == PeerKind.Group)
        {
            foreach (var title in new[] { "群成员", "群公告", "群精华", "群文件", "群相册" })
                Details.Children.Add(ActionButton(title, () => Go(GroupKey(peer, title), () => ShowGroup(peer, title))));
        }
    }
    private async Task ShowGroup(Peer peer, string title, string folder = "")
    {
        if (runtime is not { } session) return;
        var ct = NewPage(); Detail(title, DisplayName(peer));
        async Task<TResponse?> Load<TRequest, TResponse>(TRequest request, Func<TRequest, CancellationToken, Task<TResponse>> read)
            where TRequest : class where TResponse : class
        {
            var operation = new RpcOperationViewModel<TRequest, TResponse>(read, new UiDispatcher(DispatcherQueue), false); featurePage = operation;
            bool success = await operation.ExecuteAsync(request, ct);
            ct.ThrowIfCancellationRequested();
            if (featurePage != operation || runtime != session) return null;
            if (!success) throw new IOException(operation.Error ?? "群资料加载失败。");
            return operation.Result;
        }
        if (title == "群成员")
        {
            await GroupMembers(peer, ct);
        }
        else if (title == "群公告")
        {
            var r = await Load(new ListGroupNoticesRequest { GroupId = peer.PeerId }, session.ListGroupNoticesAsync);
            if (r is null) return;
            foreach (var n in r.Notices) Details.Children.Add(GroupNoticeView(n, ct));
        }
        else if (title == "群精华")
        {
            var vm = new GroupEssenceViewModel(session.ListGroupEssenceAsync, session.GetHistoryAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
            Details.Children.Add(ActionButton("刷新精华", () => ShowGroup(peer, title)));
            var status = Text("", 12); Details.Children.Add(status);
            var content = new StackPanel { Spacing = 12 }; Details.Children.Add(content);
            var rendered = new List<GroupEssence>();
            vm.Changed += () =>
            {
                if (ct.IsCancellationRequested || featurePage != vm || runtime != session) return;
                status.Text = vm.RefreshError ?? (vm.Items.Count == 0 ? "暂无精华消息" : "");
                if (rendered.Count != vm.Items.Count) { content.Children.Clear(); rendered.Clear(); }
                for (int index = 0; index < vm.Items.Count; index++)
                {
                    var item = vm.Items[index];
                    if (index < rendered.Count)
                    {
                        if (rendered[index].Equals(item)) continue;
                        content.Children[index] = GroupEssenceView(item, ct); rendered[index] = item.Clone();
                    }
                    else { content.Children.Add(GroupEssenceView(item, ct)); rendered.Add(item.Clone()); }
                }
            };
            if (!await vm.LoadAsync(peer.PeerId, ct))
            { ct.ThrowIfCancellationRequested(); if (featurePage == vm && runtime == session) throw new IOException(vm.Load.Error ?? "精华加载失败。"); }
        }
        else if (title == "群文件")
        {
            var vm = new GroupFilesViewModel(peer.PeerId, folder, session.ListGroupFilesAsync, session.DeleteGroupFolderAsync,
                session.DeleteGroupFilesAsync, session.RenameGroupFileAsync, session.MoveGroupFilesAsync, session.CreateGroupFolderAsync, new UiDispatcher(DispatcherQueue));
            featurePage = vm;
            if (!await vm.LoadAsync(ct))
            {
                ct.ThrowIfCancellationRequested();
                Details.Children.Add(Text(vm.Load.Error ?? "目录加载失败"));
                Details.Children.Add(ActionButton("重试", () => ShowGroup(peer, title, folder)));
                return;
            }
            ct.ThrowIfCancellationRequested();
            if (folder.Length > 0) Details.Children.Add(ActionButton("根目录", () => Go(GroupKey(peer, title), () => ShowGroup(peer, title))));
            else Details.Children.Add(ActionButton("新建文件夹", () => CreateGroupFolder(peer, vm, ct)));
            Details.Children.Add(Text("点击文件下载，右键打开重命名、移动和删除菜单。管理权限由 QQ 校验。", 12));
            foreach (var f in vm.Folders)
            {
                var button = ActionButton("文件夹 · " + f.Name, () => Go(GroupKey(peer, title, f.Id), () => ShowGroup(peer, title, f.Id)));
                var menu = new MenuFlyout(); var remove = new MenuFlyoutItem { Text = "删除文件夹" };
                remove.Click += async (_, _) => await Guard(async () =>
                {
                    ct.ThrowIfCancellationRequested();
                    var confirm = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "删除群文件夹？", Content = f.Name, PrimaryButtonText = "删除", CloseButtonText = "取消" };
                    if (await confirm.ShowAsync() == ContentDialogResult.Primary)
                        await RunGroupFileOperation(peer, vm, vm.DeleteFolder, new GroupFolderDeletion(f.Id), ct);
                });
                menu.Items.Add(remove); button.ContextFlyout = menu; Details.Children.Add(button);
            }
            foreach (var f in vm.Files) Details.Children.Add(GroupFileButton(peer, folder, f, vm, ct));
        }
        else if (title == "群相册")
        {
            var r = await Load(new ListGroupAlbumsRequest { GroupId = peer.PeerId }, session.ListGroupAlbumsAsync);
            if (r is null) return;
            foreach (var a in r.Albums) Details.Children.Add(ActionButton($"{a.Name} · {a.Count} 项", () => Go($"album:{peer.PeerId}:{a.Id}", () => OpenGroupAlbum(peer, a))));
        }
        if (Details.Children.Count == 1) Details.Children.Add(Text("暂无内容"));
    }
    private async void SearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args) => await Guard(() => StartSearch(args.QueryText));
    private async Task StartSearch(string query, long chatId = 0)
    {
        if (runtime is not { } searchSession || string.IsNullOrWhiteSpace(query)) return;
        _ = Guard(SaveDraft); selectedChat = 0; NewPage();
        section = "search"; listSignature = ""; SectionTitle.Text = "搜索结果"; Filter.Visibility = Visibility.Collapsed; entries.Clear();
        searchQuery = query.Trim();
        searchPager = new MessageSearchPager(searchSession.SearchMessagesAsync);
        searchPager.Reset(searchQuery, chatId);
        MoreSearchResults.Visibility = Visibility.Collapsed;
        Detail("搜索 “" + searchQuery + "”", chatId == 0 ? "全部会话 · 按时间倒序" : "当前会话 · 按时间倒序");
        await SearchPage();
    }
    private async void LoadSearchMore(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (searchPager is null || searchPager.Loading) return;
        _ = Guard(SaveDraft); NewPage(); selectedChat = 0;
        Detail("搜索 “" + searchPager.Query + "”", "按时间倒序显示匹配消息");
        MoreSearchResults.IsEnabled = false;
        try { await SearchPage(); }
        finally { MoreSearchResults.IsEnabled = true; }
    });
    private async Task SearchPage()
    {
        var pager = searchPager;
        if (pager is null || pager.Loading) return;
        var ct = pageTask?.Token ?? lifetime.Token;
        if (!await pager.LoadAsync(ct) || searchPager != pager || section != "search") return;
        ct.ThrowIfCancellationRequested();
        rendering = true; entries.Clear();
        var contacts = peerIndex.Values.Where(p => pager.ChatId == 0 && (p.IsFriend || p.Kind == PeerKind.Group)
            && (DisplayName(p).Contains(pager.Query, StringComparison.OrdinalIgnoreCase)
                || p.PeerId.ToString().Contains(pager.Query, StringComparison.Ordinal))).ToList();
        foreach (var p in contacts) entries.Add(new(DisplayName(p), p.Kind == PeerKind.Group ? "群聊" : "联系人", "", p));
        foreach (var m in pager.Results) entries.Add(new(m.SenderName.Length > 0 ? m.SenderName : m.SenderId.ToString(), m.Text, DialogListFormat.ListTime(m.Time, DateTimeOffset.Now, TimeZoneInfo.Local), m));
        rendering = false;
        Details.Children.Clear(); Details.Children.Add(Text($"找到 {contacts.Count} 个联系人或群聊，{pager.Results.Count} 条消息。选择消息可定位到原会话。"));
        MoreSearchResults.Visibility = pager.Next is not null ? Visibility.Visible : Visibility.Collapsed;
    }
    private async void ChatOptions(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        var d = store?.Dialogs.FirstOrDefault(d => d.ChatId == selectedChat); if (d is null || api is null) return;
        var menu = new MenuFlyout();
        void Item(string label, Func<Task> run) { var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await Guard(run); menu.Items.Add(item); }
        Item("会话与通知设置", () => Go("prefs:" + d.ChatId, () => ShowDialogPreferences(d.ChatId)));
        Item("多选消息", () => { EnterSelection(); return Task.CompletedTask; });
        Item("共享媒体与文件", () => Go("shared:" + d.ChatId, () => ShowSharedMedia(d.ChatId)));
        Item("提及和回复我的消息", () => Go("mentions:" + d.ChatId, () => ShowMentions(d.ChatId)));
        if (d.Scene == Scene.Group) Item("AI 语音", () => ShowAiVoice(d.ChatId));
        Item("查看资料", () => peerIndex.GetValueOrDefault((d.PeerId, d.Scene == Scene.Group)) is { } p ? Go(ProfileKey(p), () => ShowProfile(p)) : Task.CompletedTask);
        menu.ShowAt(ChatMore); await Task.CompletedTask;
    });
}
