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
            var avatar = new PersonPicture { Width = 72, Height = 72, DisplayName = AccountAvatar.DisplayName, ProfilePicture = AccountAvatar.ProfilePicture };
            Details.Children.Add(Hero(avatar, AccountAvatar.DisplayName, api.Transport.BaseUri.Host));
            Details.Children.Add(SectionHeader("状态"));
            Details.Children.Add(Card("连接", connectionStatus, "\uE968"));
            Details.Children.Add(Card("Windows 通知", notifications?.Error is { } notificationError ? "不可用：" + notificationError : "运行期间收到新消息时提醒", "\uEA8F"));
            Details.Children.Add(Card("服务端 QQ 登录状态", "查看 NapCat 上的 QQ 是否在线，掉线时在这里扫码", "\uE8D4", click: () => Go("qq-login", ShowQqLogin)));
            Details.Children.Add(SectionHeader("账号"));
            var logout = new Button { Content = "退出登录" };
            logout.Click += async (_, _) => { logout.IsEnabled = false; try { await Guard(SignOut); } finally { logout.IsEnabled = true; } };
            Details.Children.Add(Card("退出登录", "之后需要重新输入 QQ Bridge 密码；可以选择是否保留本机缓存", "\uE7E8", logout));
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
            var theme = new ComboBox { ItemsSource = new[] { "跟随系统", "浅色", "深色" }, SelectedIndex = (int)Root.RequestedTheme, MinWidth = 160 };
            theme.SelectionChanged += async (_, _) => await Guard(() =>
            {
                if (theme.SelectedIndex < 0) return Task.CompletedTask;
                var value = (ElementTheme)theme.SelectedIndex;
                (AppearanceSettings.Load() with { Theme = value }).Save(); Root.RequestedTheme = value;
                return Task.CompletedTask;
            });
            Details.Children.Add(Card("主题", "跟随 Windows，或固定浅色 / 深色", "\uE790", theme));
            var reset = new Button { Content = "恢复默认" };
            reset.Click += (_, _) => { listPaneWidth = AppearanceSettings.DefaultListPaneWidth; ApplyAdaptiveLayout(); SaveListPaneWidth(); };
            Details.Children.Add(Card("会话列表宽度", "拖动列表右边的分隔线调整，双击分隔线也能恢复", "\uE89F", reset));
            return;
        }
        if (name == "关于")
        {
            var icon = new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/AppIcon.png")), Width = 72, Height = 72 };
            string version = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "";
            Details.Children.Add(Hero(icon, "BetterChat", "QQ Bridge 的 Windows 原生客户端", "WinUI 3 · Fluent Design · ConnectRPC" + (version.Length > 0 ? " · " + version : "")));
            Details.Children.Add(SectionHeader("快捷键"));
            foreach (var (keys, what, glyph) in new[] { ("Ctrl + K", "搜索消息、联系人和群聊", "\uE721"), ("Ctrl + F", "在当前会话中查找", "\uE773"),
                ("Enter / Shift + Enter", "发送 / 换行", "\uE724"), ("Alt + ← / 鼠标返回键", "返回上一页", "\uE72B"), ("← → / Esc", "查看器里切换图片 / 关闭", "\uEB9F") })
                Details.Children.Add(Card(what, null, glyph, CardValue(keys)));
            return;
        }        if (api is null) { Details.Children.Add(Text("请先连接服务器。")); return; }
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
                bool phone = d.Platform.Contains("ios", StringComparison.OrdinalIgnoreCase) || d.Platform.Contains("android", StringComparison.OrdinalIgnoreCase);
                FrameworkElement action = d.Current ? CardValue("当前设备") : new Button { Content = "移除" };
                var card = Card(d.Name, d.Platform + " · 最近活动 " + DateTimeOffset.FromUnixTimeSeconds(d.LastSeenAt).ToLocalTime().ToString("g"), phone ? "\uE8EA" : "\uE7F4", action);
                if (action is Button remove) remove.Click += async (_, _) => await Guard(async () =>
                {
                    var confirm = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "移除设备？", Content = d.Name + " 将无法继续访问服务器。", PrimaryButtonText = "移除", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
                    if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                    ct.ThrowIfCancellationRequested();
                    if (runtime != deviceSession) return;
                    if (!await vm.RevokeAsync(d.Id, ct))
                    {
                        ct.ThrowIfCancellationRequested();
                        throw new IOException((vm.Revoke.Error ?? "设备移除失败。") + (vm.Revoke.OutcomeUncertain ? " 请刷新设备列表确认结果。" : ""));
                    }
                    ct.ThrowIfCancellationRequested();
                    Details.Children.Remove(card);
                });
                Details.Children.Add(card);
            }        }
        else if (name == "存储")
        {
            if (runtime is not { } storageSession) return;
            var load = new RpcOperationViewModel<GetStorageOverviewRequest, GetStorageOverviewResponse>(storageSession.GetStorageOverviewAsync, new UiDispatcher(DispatcherQueue), false); featurePage = load;
            if (!await load.ExecuteAsync(new() { Limit = 30 }, ct))
            {
                ct.ThrowIfCancellationRequested();
                if (featurePage != load || runtime != storageSession) return;
                throw new IOException(load.Error ?? "存储概览加载失败。");
            }
            ct.ThrowIfCancellationRequested();
            if (featurePage != load || runtime != storageSession) return;
            var r = load.Result!;
            Details.Children.Add(Hero(GlyphTile("\uEDA2"), "已使用 " + Bytes(r.PhysicalBytes), $"去重节省 {Bytes(r.DedupSavedBytes)} · {r.BlobCount:N0} 份媒体", $"热存储 {Bytes(r.HotBytes)} · 冷存储 {Bytes(r.ColdBytes)}"));
            Details.Children.Add(SectionHeader("服务端媒体"));
            foreach (var c in r.Categories.OrderByDescending(c => c.Bytes))
            {
                string category = c.Category;
                Details.Children.Add(Card(Category(category), $"{c.Count:N0} 项", CategoryGlyph(category), CardValue(Bytes(c.Bytes)),
                    StorageCategories.HasChats(category) ? () => Go("storage-chats:" + category, () => ShowStorageChats(category)) : null));
            }
            Details.Children.Add(SectionHeader("策略与本机"));
            Details.Children.Add(Card("全局存储策略", "原件保留天数、自动下载上限、冷存储下沉", "\uE713", click: () => Go($"policy:{PolicyScope.Global}::", () => ShowStoragePolicy(PolicyScope.Global))));
            foreach (var (scene, label) in new[] { (Scene.Friend, "私聊"), (Scene.Group, "群聊"), (Scene.Temp, "临时会话") })
                Details.Children.Add(Card(label + "存储策略", "覆盖全局策略", "\uE71D", click: () => Go($"policy:{PolicyScope.Scene}:{scene}:", () => ShowStoragePolicy(PolicyScope.Scene, scene))));
            Details.Children.Add(Card("本机预览缓存", "缩略图、头像和表情的本地缓存", "\uE8B7", click: () => Go("preview-cache", ShowPreviewCache)));
        }
        else if (name == "通话记录")
        {
            var r = await api.ListCallsAsync(new() { Limit = 50 }, ct); ct.ThrowIfCancellationRequested();
            if (r.Calls.Count == 0) Details.Children.Add(Card("暂无通话记录", null, "\uE717"));
            foreach (var c in r.Calls)
                Details.Children.Add(Card(c.PeerName, $"{(c.Incoming ? "来电" : "呼出")} · {c.Phase}", c.Incoming ? "\uE77E" : "\uE717",
                    CardValue(DateTimeOffset.FromUnixTimeSeconds(c.InviteAt).ToLocalTime().ToString("g"))));
        }
    }
    private static string CategoryGlyph(string key) => key switch { "image" => "\uEB9F", "video" => "\uE714", "record" => "\uE720", "file" or "group_file" => "\uE8A5", "avatar" => "\uE77B", "sticker" => "\uE76E", _ => "\uE8B7" };    // 退出登录：先问保留还是清除本机缓存（同 iOS）。缓存按服务器 + 设备凭据分库，重新登录会拿到新凭据、新库，
    // 所以「保留」只是不删旧库；「清除」在连接全部关闭后删掉数据库和媒体预览目录。
    private async Task SignOut()
    {
        var session = runtime; if (session is null) return;
        var choice = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "退出登录？",
            Content = "本机缓存包括消息、联系人和媒体预览。清除后这台电脑上不再留有这个账号的聊天记录。",
            PrimaryButtonText = "退出并保留缓存", SecondaryButtonText = "退出并清除缓存", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close
        };
        var answer = await choice.ShowAsync();
        if (answer == ContentDialogResult.None || runtime != session) return;
        var saved = SessionSettings.Load();
        string? cache = saved is null ? null : SessionSettings.CachePath(saved.Server, saved.Token);
        var result = await LogoutCoordinator.RunAsync(() => PersistUnsavedDrafts(session), SessionSettings.Clear,
            ct => session.Api.LogoutAsync(new(), ct), Disconnect);
        lifetime = new();
        connectionStatus = "尚未连接"; RefreshList(); ShowWelcome();
        string? cacheError = null;
        if (answer == ContentDialogResult.Secondary && cache is not null)
        {
            try { SessionSettings.DeleteCache(cache); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { cacheError = e.Message; }
        }
        if (!result.RemoteRevoked || cacheError is not null)
        {
            Notice.Severity = InfoBarSeverity.Warning;
            Notice.Message = "已退出本机账号。" + (result.RemoteRevoked ? "" : "服务端注销未确认，可在其他设备的设备管理中撤销此设备。")
                + (cacheError is null ? "" : "本机缓存没有完全删除：" + cacheError);
            Notice.IsOpen = true;
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
        bool group = peer.Kind == PeerKind.Group;
        Detail(DisplayName(peer), group ? "群资料" : "联系人资料");
        async Task Open()
        {
            if (runtime != profileSession) return;
            bool opened = await vm.Open.ExecuteAsync(new(), profileToken);
            if (featurePage != vm || runtime != profileSession) return;
            if (!opened) { profileToken.ThrowIfCancellationRequested(); throw new IOException(vm.Open.Error ?? "无法打开会话。"); }
            profileToken.ThrowIfCancellationRequested();
            if (runtime == profileSession) { long target = vm.Open.Result!.ChatId; await Go(ChatKey(target), () => OpenChat(target)); }
        }
        async Task Refresh()
        {
            if (runtime != profileSession) return;
            bool refreshed = await vm.Refresh.ExecuteAsync(new(), profileToken);
            if (featurePage != vm || runtime != profileSession) return;
            if (!refreshed) { profileToken.ThrowIfCancellationRequested(); throw new IOException(vm.Refresh.Error ?? "资料刷新失败。"); }
            profileToken.ThrowIfCancellationRequested();
            if (runtime == profileSession) ShowProfile(vm.Refresh.Result!, viaGroup);
        }
        // 页头：大头像、名字、号码、签名 / 人数。
        var avatar = new PersonPicture { DisplayName = DisplayName(peer), Width = 88, Height = 88, Tag = peer.PeerId };
        avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, peer.PeerId, group);
        string name = DisplayName(peer);
        string realName = peer.Remark.Length > 0 && peer.Name.Length > 0 && peer.Name != name ? "昵称 " + peer.Name : "";
        Details.Children.Add(Hero(avatar, name, (group ? "群号 " : "QQ ") + peer.PeerId, realName, group ? $"{peer.MemberCount} 位成员" : peer.Sign));
        Details.Children.Add(ActionRow(("发消息", "\uE8BD", Open), ("刷新资料", "\uE72C", Refresh)));
        if (group)
        {
            Details.Children.Add(SectionHeader("群聊"));
            foreach (var (title, description, glyph) in new[] { ("群成员", $"{peer.MemberCount} 位成员", "\uE716"), ("群公告", "群主和管理员发布的公告", "\uE789"),
                ("群精华", "被设为精华的消息", "\uE734"), ("群文件", "浏览、下载和管理群文件", "\uE8B7"), ("群相册", "群里共享的照片", "\uEB9F") })
                Details.Children.Add(Card(title, description, glyph, click: () => Go(GroupKey(peer, title), () => ShowGroup(peer, title))));
        }
        if (peer.Kind == PeerKind.User && peer.IsFriend && runtime is { } contactSession)
        {
            Details.Children.Add(SectionHeader("好友"));
            var delete = new Button { Content = "删除好友" };
            delete.Click += async (_, _) => await Guard(async () =>
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
                    Content = $"确定删除 {DisplayName(peer)}（{peer.PeerId}）吗？", PrimaryButtonText = "删除", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
                if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                ct.ThrowIfCancellationRequested();
                if (runtime != contactSession || featurePage != vm) return;
                var operation = contactSession.Contacts.DeleteFriend;
                if (!await operation.ExecuteAsync(new(peer.PeerId), ct))
                    throw new IOException((operation.Error ?? "删除未完成。") + (operation.OutcomeUncertain ? " 服务端结果待确认，请刷新列表。" : ""));
                ct.ThrowIfCancellationRequested();
                if (runtime != contactSession || featurePage != vm) return;
                Detail("好友已删除", DisplayName(peer));
            });
            Details.Children.Add(Card("删除好友", "双方都会从好友列表里移除", "\uE74D", delete));
        }
        if (section == "contacts")
        {
            var all = new HyperlinkButton { Content = "所有联系人分组" };
            all.Click += (_, _) => ShowContactsOverview();
            Details.Children.Add(all);
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
            var loaded = PageLoading("正在从 QQ 读取" + title + "…");
            bool success;
            try { success = await operation.ExecuteAsync(request, ct); } finally { loaded(); }
            ct.ThrowIfCancellationRequested();
            if (featurePage != operation || runtime != session) return null;
            if (!success) { PageError(title + "加载失败", operation.Error, () => ShowGroup(peer, title, folder)); return null; }
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
            Details.Children.Add(ActionRow(("刷新", "\uE72C", () => ShowGroup(peer, title))));
            var status = new TextBlock { Style = Res<Style>("SecondaryCaptionTextBlockStyle") }; Details.Children.Add(status);
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
            var loadedEssence = PageLoading("正在从 QQ 读取群精华…");
            bool essenceLoaded;
            try { essenceLoaded = await vm.LoadAsync(peer.PeerId, ct); } finally { loadedEssence(); }
            if (!essenceLoaded)
            { ct.ThrowIfCancellationRequested(); if (featurePage == vm && runtime == session) throw new IOException(vm.Load.Error ?? "精华加载失败。"); }
        }
        else if (title == "群文件")
        {
            var vm = new GroupFilesViewModel(peer.PeerId, folder, session.ListGroupFilesAsync, session.DeleteGroupFolderAsync,
                session.DeleteGroupFilesAsync, session.RenameGroupFileAsync, session.MoveGroupFilesAsync, session.CreateGroupFolderAsync, new UiDispatcher(DispatcherQueue));
            featurePage = vm;
            var loadedFiles = PageLoading("正在从 QQ 读取群文件…");
            bool listed;
            try { listed = await vm.LoadAsync(ct); } finally { loadedFiles(); }
            if (!listed)
            {
                ct.ThrowIfCancellationRequested();
                Details.Children.Add(Card("目录加载失败", vm.Load.Error == "QQ is offline" ? "服务端的 QQ 当前离线，恢复后再试" : vm.Load.Error, "\uE783"));
                Details.Children.Add(ActionRow(("重试", "\uE72C", () => ShowGroup(peer, title, folder))));
                return;
            }
            ct.ThrowIfCancellationRequested();
            if (folder.Length > 0) Details.Children.Add(ActionRow(("返回根目录", "\uE72B", () => Go(GroupKey(peer, title), () => ShowGroup(peer, title)))));
            else Details.Children.Add(ActionRow(("新建文件夹", "\uE8F4", () => CreateGroupFolder(peer, vm, ct))));
            Details.Children.Add(new TextBlock { Text = "点击文件下载并打开；右键可以重命名、移动和删除（权限由 QQ 校验）。", Style = Res<Style>("SecondaryCaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
            if (vm.Folders.Count == 0 && vm.Files.Count == 0) Details.Children.Add(Card("这里还没有文件", null, "\uE8B7"));
            foreach (var f in vm.Folders)
            {
                var button = FileRow("\uE8B7", f.Name, $"{f.FileCount} 个文件" + (f.CreatorName.Length > 0 ? " · " + f.CreatorName : ""), () => Go(GroupKey(peer, title, f.Id), () => ShowGroup(peer, title, f.Id)));
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
            foreach (var a in r.Albums)
                Details.Children.Add(Card(a.Name, $"{a.Count} 张" + (a.CreatorName.Length > 0 ? " · " + a.CreatorName + " 创建" : "") + (a.Desc.Length > 0 ? " · " + a.Desc : ""), "\uEB9F",
                    click: () => Go($"album:{peer.PeerId}:{a.Id}", () => OpenGroupAlbum(peer, a))));
            if (r.Albums.Count == 0) Details.Children.Add(Card("还没有相册", null, "\uEB9F"));
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
        // 会话索引只在消息分区刷新；刚启动或从联系人分区搜索时可能还没有这些会话，先从本地库补上，标题和头像才不是「会话 1234」。
        if (runtime is { } session)
            foreach (long chat in pager.Results.Select(m => m.ChatId).Distinct().Where(c => !dialogIndex.ContainsKey(c)).ToList())
                if (await session.Repository.GetDialogAsync(chat, ct) is { } stored) dialogIndex[chat] = stored;
        if (searchPager != pager || section != "search") return;
        rendering = true; entries.Clear();
        var contacts = peerIndex.Values.Where(p => pager.ChatId == 0 && (p.IsFriend || p.Kind == PeerKind.Group)
            && (DisplayName(p).Contains(pager.Query, StringComparison.OrdinalIgnoreCase)
                || p.PeerId.ToString().Contains(pager.Query, StringComparison.Ordinal))).ToList();
        foreach (var p in contacts) entries.Add(new(DisplayName(p), p.Kind == PeerKind.Group ? "群聊" : "联系人", "", p));
        // 和 Mac 侧栏搜索一样：全局搜索时标题是会话名、头像是会话头像，预览前写发送人；会话内查找时标题直接是发送人。
        foreach (var m in pager.Results)
        {
            string sender = m.SenderName.Length > 0 ? m.SenderName : PeerName(m.SenderId, Scene.Friend);
            string text = m.Text.Length > 0 ? m.Text : "[消息]";
            string time = DialogListFormat.ListTime(m.Time, DateTimeOffset.Now, TimeZoneInfo.Local);
            entries.Add(pager.ChatId == 0 ? new(PeerNameForChat(m.ChatId), text, time, m) { SenderPrefix = sender + "：" } : new(sender, text, time, m));
        }
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
