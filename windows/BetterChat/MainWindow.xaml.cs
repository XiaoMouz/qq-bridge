using System.Collections.ObjectModel;
using System.Security.Cryptography;
using BetterChat.Application;
using BetterChat.Core;
using BetterChat.Infrastructure;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Text;
using ProtoMessage = Qqbridge.V1.Message;

namespace BetterChat;

public sealed record TimelineEntry(string Key, object Value)
{
    public ProtoMessage? Message => Value switch { MessageItem item => item.Message, ProtoMessage m => m, _ => null };
    public override string ToString() => Value switch { MessageItem { Message: var m } => m.SenderName + "：" + m.Text, TimeHeader => "时间", ChatEvent => "系统事件", _ => "发送中的消息" };
}
// 时间线里的一条消息；ShowsSender 由前后消息决定（群里同一个人连续发的只在第一条显示名字和头像）。
public sealed record MessageItem(ProtoMessage Message, bool ShowsSender);
// 隔了 5 分钟以上的时间分隔条。
public sealed record TimeHeader(long Time);

public sealed partial class MainWindow : Window
{
    private BridgeApi? api;
    private ILocalStore? store;
    private ClientSessionRuntime? runtime;
    private CancellationTokenSource lifetime = new();
    private CancellationTokenSource? pageTask;
    private IDisposable? featurePage;
    private readonly DispatcherTimer draftTimer = new() { Interval = TimeSpan.FromMilliseconds(800) };
    private readonly DispatcherTimer activeTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly Dictionary<long, ComposerDocument> drafts = [];
    private readonly Dictionary<long, long> replies = [];
    private readonly ObservableCollection<ListEntry> entries = [];
    private string section = "messages";
    private long? contactCategoryId;
    private long contactRevision;
    private bool contactsOverview;
    private long selectedChat;
    private long replySeq;
    private bool rendering;
    private Task? timelineRenderTask;
    private long timelineRenderRevision;
    private bool sending;
    private bool ready;
    private bool closingWindow;
    private bool allowWindowClose;
    private Task? disconnectTask;
    private int refreshQueued;
    private string searchQuery = "";
    private MessageSearchPager? searchPager;
    private string messageSignature = "";
    private HistoryWindow? historyWindow;
    private bool historyLoading;
    private bool followLatest;
    private bool scrollQueued;
    private long? historyAnchor;
    private Dictionary<string, TimelineEntry> messageViews = [];
    private IReadOnlyDictionary<(long, bool), Peer> peerIndex = new Dictionary<(long, bool), Peer>();
    private Dictionary<long, Dialog> dialogIndex = [];
    private string listSignature = "";
    private readonly HashSet<long> dirtyDrafts = [];
    private readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private string connectionStatus = "尚未连接";
    private readonly BetterChat.Application.DetailNavigator navigator = new();

    public MainWindow()
    {
        InitializeComponent();
        InitializeNotifications();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        InitializeChatState();
        refreshTimer.Tick += (_, _) => { refreshTimer.Stop(); Interlocked.Exchange(ref refreshQueued, 0); UpdateUnreadBadge(); RefreshList(); UpdateFloatingButtons(); UpdateChatTitle(); if (selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible) _ = Guard(RenderMessages); };
        Root.RequestedTheme = AppearanceSettings.Load().Theme;
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1380, 900));
        Items.ItemsSource = entries;
        Messages.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler((_, _) => followLatest = false), true);
        Messages.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => followLatest = false), true);
        draftTimer.Tick += async (_, _) => { draftTimer.Stop(); await Guard(SaveDraft); };
        activeTimer.Tick += async (_, _) => { if (windowActive && selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible) await UpdateActiveChat(); };
        Root.Loaded += async (_, _) =>
        {
            if (ready) return; ready = true; ShowWelcome();
            await Guard(async () =>
            {
                SessionSettings.RemoveLegacyPlaintext();
                if (SessionSettings.Load() is { } saved)
                {
                    try { await Connect(saved.Server, saved.Token); }
                    catch (RpcException e) when (e.Code == "unauthenticated")
                    {
                        SessionSettings.Clear(); ShowConnection();
                        throw new InvalidOperationException("登录已失效，请重新输入账号密码。");
                    }
                }
                else if (SessionSettings.LoadError is { } error)
                {
                    ShowConnection(); Notice.Severity = InfoBarSeverity.Warning; Notice.Message = error; Notice.IsOpen = true;
                }
                else ShowWelcome();
            });
        };
        AppWindow.Closing += async (_, args) =>
        {
            if (allowWindowClose) return;
            args.Cancel = true;
            if (closingWindow) return;
            closingWindow = true;
            try
            {
                await Disconnect();
                allowWindowClose = true; Close();
            }
            catch (Exception error)
            {
                closingWindow = false;
                Notice.Severity = InfoBarSeverity.Error; Notice.Message = "退出前保存失败：" + error.Message; Notice.IsOpen = true;
            }
        };
        var find = new KeyboardAccelerator { Key = VirtualKey.K, Modifiers = VirtualKeyModifiers.Control };
        find.Invoked += (_, e) => { if (Workspace.Visibility == Visibility.Visible) { Search.Focus(FocusState.Keyboard); e.Handled = true; } };
        // 根节点注册全局快捷键，但不能让整个窗口成为快捷键提示的悬浮区域。
        Root.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        ToolTipService.SetToolTip(Search, "搜索消息、联系人和群聊 (Ctrl+K)");
        Root.KeyboardAccelerators.Add(find);
        InitializeShell();
    }

    private async Task Guard(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception e) { Notice.Severity = InfoBarSeverity.Error; Notice.Message = e.Message; Notice.IsOpen = true; }
    }
    private CancellationToken NewPage()
    {
        StopVoice(); if (Viewer.Visibility == Visibility.Visible) CloseViewer();
        featurePage?.Dispose(); featurePage = null;
        pageTask?.Cancel(); pageTask?.Dispose();
        pageTask = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        return pageTask.Token;
    }
    private static TextBlock Text(string text, double size = 14) => new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private Button ActionButton(string label, Func<Task> action)
    {
        var b = new Button { Content = label }; b.Click += async (_, _) => { b.IsEnabled = false; await Guard(action); b.IsEnabled = true; }; return b;
    }
    private void Detail(string title, string subtitle = "")
    {
        contactsOverview = false;
        ContentTitle.Text = title; ContentSubtitle.Text = subtitle;
        ExitSelection(); CloseChatSearch();
        ChatPanel.Visibility = ComposerPanel.Visibility = ChatMore.Visibility = ChatSearchButton.Visibility = Visibility.Collapsed;
        _ = UpdateActiveChat();
        DetailScroll.Visibility = Visibility.Visible; Details.Children.Clear();
    }
    private void ShowWelcome()
    {
        navigator.Clear(); UpdateUnreadBadge();
        Workspace.Visibility = Visibility.Collapsed; Search.Visibility = Visibility.Collapsed;
        Onboarding.Visibility = Visibility.Visible;
        AccountButton.Visibility = Visibility.Collapsed;
        OnboardingSubtitle.Text = "在 Windows 上，继续你的 QQ 聊天。";
        OnboardingContent.Children.Clear();
        OnboardingContent.Children.Add(Text("登录你的 QQ Bridge，聊天记录、联系人和草稿将在设备间同步。"));
        var start = ActionButton("开始使用", () => { ShowConnection(); return Task.CompletedTask; });
        start.Style = (Style)Microsoft.UI.Xaml.Application.Current.Resources["AccentButtonStyle"];
        start.HorizontalAlignment = HorizontalAlignment.Stretch;
        OnboardingContent.Children.Add(start);
    }
    private async Task Connect(string server, string token)
    {
        if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("登录凭据已失效，请重新登录。");
        var transport = new ConnectClient(new Uri(server.Trim())) { Token = token.Trim() };
        var candidate = new BridgeApi(transport);
        GetStateResponse accountState;
        try { accountState = await candidate.GetStateAsync(new(), lifetime.Token); }
        catch { transport.Dispose(); throw; }
        transport.Dispose();
        await Disconnect(); lifetime = new();
        runtime = await ClientSessionRuntime.CreateAsync(new Uri(server.Trim()), token.Trim(), SessionSettings.CachePath(server, token), new UiDispatcher(DispatcherQueue), lifetime.Token);
        candidate = runtime.Api;
        api = candidate;
        readReceipts = runtime.ReadReceipts;
        store = runtime.LegacyStore;
        runtime.SeedOwnUsers(accountState.QqAccounts.Select(a => a.Uin));
        SessionSettings.Save(server, token);
        var currentRuntime = runtime;
        AttachNotifications(currentRuntime);
        store.Changed += QueueRefresh;
        runtime.ConnectionStatus += status => DispatcherQueue.TryEnqueue(async () =>
        {
            if (runtime != currentRuntime) return;
            connectionStatus = status;
            if (status == "设备令牌已失效，请重新连接")
            {
                SessionSettings.Clear();
                await Disconnect(); lifetime = new();
                ShowConnection();
            }
        });
        runtime.Ephemeral += update => DispatcherQueue.TryEnqueue(() =>
        {
            if (runtime != currentRuntime) return;
            if (update.Typing?.ChatId == selectedChat) ContentSubtitle.Text = update.Typing.Text;
            if (update.MediaReady is { } readyMedia)
            {
                ForwardMediaReady?.Invoke(readyMedia);
                if (featurePage is GroupEssenceViewModel essence)
                {
                    var token = pageTask?.Token ?? lifetime.Token;
                    _ = Guard(() => essence.MediaReadyAsync(readyMedia, token));
                }
                requestedPreviews.Remove((readyMedia.ChatId, readyMedia.Seq, readyMedia.Ord));
                if (readyMedia.ChatId == selectedChat) QueueRefresh();
            }
            if (update.Call is { } call) { Notice.Severity = InfoBarSeverity.Informational; Notice.Message = $"通话：{call.Call.PeerName} · {call.Call.Phase}"; Notice.IsOpen = true; }
        });
        var sessionToken = lifetime.Token;
        runtime.Dialogs.Load.PropertyChanged += DialogListLoaded;
        runtime.Contacts.PropertyChanged += ContactsChanged;
        runtime.Contacts.Load.PropertyChanged += ContactsChanged;
        runtime.Start();
        Onboarding.Visibility = Visibility.Collapsed; Workspace.Visibility = Visibility.Visible; Search.Visibility = Visibility.Visible;
        Notice.IsOpen = false;
        activeTimer.Start(); Nav.SelectedItem = MessagesNavItem; RefreshList();
        navigator.Clear();
        Detail("选择一个会话", "消息和联系人正在同步，断线时仍可浏览已缓存的消息。");
        var account = accountState.QqAccounts.FirstOrDefault();
        if (account is not null)
        {
            AccountAvatar.DisplayName = account.Nickname.Length > 0 ? account.Nickname : account.Uin.ToString();
            AccountButton.Visibility = Visibility.Visible;
            ToolTipService.SetToolTip(AccountButton, AccountAvatar.DisplayName);
            _ = LoadAccountAvatar(candidate, account.Uin, sessionToken);
        }
        RunDebugJump();
    }
    private async Task LoadAccountAvatar(BridgeApi sessionApi, long userId, CancellationToken ct)
    {
        try
        {
            var request = new GetAvatarsRequest(); request.UserIds.Add(userId);
            var avatars = await SessionFor(sessionApi).GetAvatarsAsync(request, ct);
            string? sha = avatars.Avatars.FirstOrDefault(a => a.UserId == userId)?.Sha256;
            if (string.IsNullOrEmpty(sha)) return;
            var sign = new SignMediaUrlsRequest(); sign.Sha256.Add(sha);
            var response = await SessionFor(sessionApi).SignMediaUrlsAsync(sign, ct);
            ct.ThrowIfCancellationRequested();
            if (api != sessionApi) return;
            var url = response.Urls.FirstOrDefault(u => u.Sha256 == sha)?.Url;
            if (!string.IsNullOrEmpty(url)) AccountAvatar.ProfilePicture = new BitmapImage(sessionApi.Transport.ResolveMedia(url));
        }
        catch (OperationCanceledException) { }
        catch (Exception) { /* 头像加载失败时保留当前账号的姓名占位，不阻止登录。 */ }
    }
    private Task Disconnect()
    {
        if (disconnectTask is { IsCompleted: false }) return disconnectTask;
        return disconnectTask = DisconnectCore();
    }
    private async Task DisconnectCore()
    {
        if (recordingSession is { } recorder) await recorder.DisposeAsync();
        StopVoice(); voicePlayer?.Dispose(); voicePlayer = null; CloseViewer();
        readTimer.Stop(); readReceipts = null;
        activeTimer.Stop(); draftTimer.Stop();
        var closing = runtime;
        Workspace.IsHitTestVisible = false; Composer.IsEnabled = false; Search.IsEnabled = false;
        // 仍在防抖窗口内的编辑也先进入持久化队列，随后才取消账号任务。
        try { if (closing is not null) await PersistUnsavedDrafts(closing); }
        catch { Workspace.IsHitTestVisible = true; Composer.IsEnabled = true; Search.IsEnabled = true; throw; }
        runtime = null;
        await ClearNotifications();
        featurePage?.Dispose(); featurePage = null;
        lifetime.Cancel(); pageTask?.Cancel();
        if (closing is not null)
        {
            closing.Dialogs.Load.PropertyChanged -= DialogListLoaded;
            closing.Contacts.PropertyChanged -= ContactsChanged;
            closing.Contacts.Load.PropertyChanged -= ContactsChanged;
        }
        if (store is not null) store.Changed -= QueueRefresh;
        try { if (closing is not null) await closing.DisposeAsync(); }
        finally
        {
            // 运行时释放资源后仍可能抛出在途错误；窗口必须清除已关闭账号的全部投影。
            store = null; api = null; selectedChat = 0; drafts.Clear(); replies.Clear(); replySeq = 0;
            AccountAvatar.ProfilePicture = null; AccountAvatar.DisplayName = ""; AccountButton.Visibility = Visibility.Collapsed;
            ClearAvatars(); requestedPreviews.Clear(); signedMedia.Clear(); peerIndex = new Dictionary<(long, bool), Peer>(); dialogIndex.Clear(); listSignature = ""; dirtyDrafts.Clear(); refreshTimer.Stop(); Interlocked.Exchange(ref refreshQueued, 0);
            searchPager = null; searchQuery = ""; historyWindow = null; historyError = "";
            timelineRenderRevision++; messageSignature = ""; messageViews.Clear(); Messages.Items.Clear(); entries.Clear();
            Details.Children.Clear(); Composer.Text = ""; UpdateReply(); MoreSearchResults.Visibility = Visibility.Collapsed;
            Workspace.Visibility = Visibility.Collapsed; Search.Visibility = Visibility.Collapsed;
            Workspace.IsHitTestVisible = true; Composer.IsEnabled = true; Search.IsEnabled = true;
            ShowWelcome();
        }
    }
    private Task PersistUnsavedDrafts(ClientSessionRuntime session)
    {
        var pending = new List<Task>();
        foreach (long chat in dirtyDrafts.ToArray())
        {
            var request = new SaveDraftRequest { ChatId = chat, ReplyToSeq = chat == selectedChat ? replySeq : replies.GetValueOrDefault(chat) };
            if (drafts.TryGetValue(chat, out var document)) request.Segments.Add(document.Segments());
            pending.Add(session.PersistDraftAsync(request));
        }
        return Task.WhenAll(pending);
    }
    private void DialogListLoaded(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (runtime?.Dialogs.Load.State != OperationState.Succeeded) return;
        if (runtime.Dialogs.Load.Result is { } snapshot) peerIndex = snapshot.DisplayPeers;
        listSignature = ""; QueueRefresh();
    }
    private void QueueRefresh()
    {
        if (Interlocked.Exchange(ref refreshQueued, 1) != 0) return;
        DispatcherQueue.TryEnqueue(() => refreshTimer.Start());
    }
    private string PeerName(long peerId, Scene scene)
    {
        var p = peerIndex.GetValueOrDefault((peerId, scene == Scene.Group));
        return p is null ? peerId.ToString() : DisplayName(p);
    }
    private static string DisplayName(Peer p) => DialogListFormat.HasVisibleText(p.Remark) ? p.Remark : DialogListFormat.HasVisibleText(p.Name) ? p.Name : p.PeerId.ToString();
    private void RefreshList()
    {
        if (!ready || section == "search") return;
        int filter = FilterIndex;
        // 日期也算进签名：跨天后「今天 / 昨天」的时间文字要重新算。
        string signature = $"{section}:{filter}:{store?.DialogRevision}:{store?.PeerRevision}:{contactRevision}:{contactCategoryId}:{DateTime.Today:yyyyMMdd}";
        if (signature == listSignature) return;
        listSignature = signature;
        rendering = true;
        var next = new List<ListEntry>();
        if (section == "messages" && store is not null)
        {
            var rows = runtime?.Dialogs.Items.ToArray() ?? [];
            dialogIndex = rows.ToDictionary(r => r.ChatId, r => r.Snapshot);
            var names = rows.ToDictionary(r => r.ChatId, r => r.Title);
            var own = runtime?.OwnUsers ?? new HashSet<long>();
            var now = DateTimeOffset.Now;
            foreach (var d in dialogIndex.Values.Where(d => filter == 2 ? d.NotifyPolicy == "archived" : d.NotifyPolicy != "archived").Where(d => filter != 1 || d.UnreadCount > 0))
            {
                bool draft = d.Draft is { Segments.Count: > 0 };
                bool muted = DialogListFormat.IsMuted(d);
                next.Add(new(names[d.ChatId], draft ? OutgoingPreview(d.Draft!.Segments) : d.TopMessage?.Text ?? "暂无消息",
                    DialogListFormat.ListTime(d.TopTime, now, TimeZoneInfo.Local), d)
                {
                    DraftPrefix = draft ? "[草稿] " : "", SenderPrefix = DialogListFormat.SenderPrefix(d, own),
                    Unread = DialogListFormat.UnreadText(d.UnreadCount), UnreadMuted = muted, Muted = muted, Pinned = d.Pinned,
                    Mention = d.UnreadMentions > 0, Reply = d.UnreadReplies > 0, MentionAll = d.UnreadMentionAll > 0 && d.MentionAllNotify,
                });
            }
        }
        else if (section == "contacts" && store is not null)
        {
            var directory = runtime!.Contacts.Directory;
            IEnumerable<Peer> peers = filter == 0 ? directory.Friends : directory.Groups;
            if (filter == 0 && contactCategoryId is { } categoryId)
            {
                var users = directory.Categories.FirstOrDefault(c => c.Id == categoryId)?.UserIds.ToHashSet() ?? [];
                peers = peers.Where(p => users.Contains(p.PeerId));
            }
            foreach (var p in peers.OrderBy(DisplayName))
                next.Add(new(DisplayName(p), p.Kind == PeerKind.Group ? $"{p.MemberCount} 位成员" : p.Sign, "", p));
        }
        else if (section == "settings")
        {
            foreach (var (title, sub, glyph) in new[] { ("连接与账号", "账号与登录状态", ""), ("外观", "主题与阅读体验", ""), ("设备", "已连接的设备", ""),
                ("存储", "服务端空间与缓存", ""), ("服务端状态", "QQ、队列与通话桥", ""), ("存档完整性", "消息缺口与深度归档", ""),
                ("通话记录", "最近的 QQ 通话", ""), ("关于", "BetterChat for Windows", "") })
                next.Add(new(title, sub, "", title) { Glyph = glyph });
        }
        var existing = entries.ToDictionary(e => e.Key);
        var keys = next.Select(e => e.Key).ToHashSet();
        for (int i = entries.Count - 1; i >= 0; i--) if (!keys.Contains(entries[i].Key)) entries.RemoveAt(i);
        for (int i = 0; i < next.Count; i++)
        {
            if (existing.TryGetValue(next[i].Key, out var row))
            {
                row.Update(next[i]);
                if (!ReferenceEquals(entries[i], row)) entries.Move(entries.IndexOf(row), i);
            }
            else entries.Insert(i, next[i]);
        }
        if (section == "messages") Items.SelectedItem = entries.FirstOrDefault(e => e.Value is Dialog d && d.ChatId == selectedChat);
        rendering = false;
    }
    private int FilterIndex => Filter.SelectedItem is { } item ? Math.Max(0, Filter.Items.IndexOf(item)) : 0;
    private void SelectFilter(int index) => Filter.SelectedItem = index < Filter.Items.Count ? Filter.Items[index] : null;
    private void NavChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!ready || args.SelectedItemContainer is not NavigationViewItem item) return;
        _ = Guard(SaveDraft); NewPage(); selectedChat = 0;
        section = (string)item.Tag; SectionTitle.Text = section == "messages" ? "消息" : section == "contacts" ? "联系人" : "设置";
        MoreSearchResults.Visibility = Visibility.Collapsed;
        rendering = true; Filter.Items.Clear();
        foreach (string s in section == "messages" ? new[] { "全部", "未读", "群助手" } : section == "contacts" ? new[] { "好友", "群聊" } : Array.Empty<string>()) Filter.Items.Add(new SelectorBarItem { Text = s });
        Filter.Visibility = section == "settings" ? Visibility.Collapsed : Visibility.Visible;
        SelectFilter(0); rendering = false; RefreshList();
        // 切换分区是根导航：上一个分区里点进去的页面栈不再保留。分区首页在窄窗口里不占右栏，先显示列表。
        if (section == "settings") _ = Guard(() => GoLanding(SettingKey("连接与账号"), () => { ShowConnection(); return Task.CompletedTask; }));
        else if (api is null) ShowWelcome();
        else if (section == "contacts")
        {
            contactCategoryId = null;
            _ = Guard(() => GoLanding("contacts", () => { ShowContactsOverview(); return Task.CompletedTask; }));
            _ = Guard(() => runtime!.Contacts.LoadAsync(ct: lifetime.Token));
        }
        else { navigator.Clear(); Detail("选择一个会话", "从左侧列表继续"); }
    }
    private void FilterChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) { if (!rendering) RefreshList(); }
    private async void ItemSelected(object sender, SelectionChangedEventArgs e)
    {
        if (rendering || Items.SelectedItem is not ListEntry entry) return;
        await Guard(async () =>
        {
            if (entry.Value is Dialog d) await GoRoot(ChatKey(d.ChatId), () => OpenChat(d.ChatId));
            else if (entry.Value is ProtoMessage m) await GoRoot(ChatKey(m.ChatId), () => OpenChat(m.ChatId, m.Seq));
            else if (entry.Value is Peer p) await GoRoot(ProfileKey(p), () => { _ = Guard(SaveDraft); NewPage(); selectedChat = 0; ShowProfile(p); return Task.CompletedTask; });
            else if (entry.Value is string s) await GoRoot(SettingKey(s), () => { NewPage(); return ShowSetting(s); });
        });
    }
    private async Task OpenChat(long chat, long? anchor = null)
    {
        if (api is null || store is null || runtime is null) return;
        var session = runtime;
        _ = Guard(SaveDraft); var ct = NewPage(); ExitSelection(); CloseChatSearch(); selectedChat = chat; messageSignature = "";
        var window = new HistoryWindow(!anchor.HasValue); historyWindow = window; followLatest = !anchor.HasValue;
        historyError = ""; readTimer.Stop();
        historyAnchor = anchor; messageViews.Clear(); Messages.Items.Clear();
        historyLoading = true; UpdateHistoryButtons();
        var d = dialogIndex.GetValueOrDefault(chat);
        // 从通知或 -debugJump 进来时会话列表可能还没读完：从本地库补上会话，否则标题和群聊判断都会错。
        if (d is null && await session.Repository.GetDialogAsync(chat, ct) is { } stored) { d = stored; dialogIndex[chat] = stored; }
        var localDraft = await session.Repository.GetLocalDraftAsync(chat, ct);
        ct.ThrowIfCancellationRequested();
        if (localDraft is not null) dirtyDrafts.Add(chat);
        ContentTitle.Text = d is null ? "聊天" : PeerName(d.PeerId, d.Scene);
        ContentSubtitle.Text = d?.Scene == Scene.Group ? "群聊" : "私聊";
        DetailScroll.Visibility = Visibility.Collapsed;
        ChatPanel.Visibility = ComposerPanel.Visibility = ChatMore.Visibility = ChatSearchButton.Visibility = Visibility.Visible;
        rendering = true;
        if (!drafts.TryGetValue(chat, out var document))
        {
            document = ComposerDocument.FromSegments(localDraft?.Segments.AsEnumerable() ?? d?.Draft?.Segments.AsEnumerable() ?? [], id => PeerName(id, Scene.Friend));
            drafts[chat] = document;
        }
        Composer.Text = document.Text;
        MentionButton.Visibility = d?.Scene == Scene.Group ? Visibility.Visible : Visibility.Collapsed;
        replySeq = replies.GetValueOrDefault(chat, localDraft?.ReplyToSeq ?? d?.Draft?.ReplyToSeq ?? 0); UpdateReply(); RenderAttachments(); rendering = false;
        await RenderMessages();
        ct.ThrowIfCancellationRequested();
        QueueScrollToLatest();
        try
        {
            if (!anchor.HasValue && await session.Repository.GetLatestHistoryAsync(chat, ct) is { } cachedHistory)
            {
                ct.ThrowIfCancellationRequested(); window.Start(cachedHistory); await RenderMessages(); ct.ThrowIfCancellationRequested(); QueueScrollToLatest();
            }
            var request = new GetHistoryRequest { ChatId = chat, Direction = anchor.HasValue ? HistoryDirection.Around : HistoryDirection.Older, Limit = 60 };
            if (anchor.HasValue) request.AnchorSeq = anchor.Value;
            var history = await session.GetHistoryAsync(request, ct);
            ct.ThrowIfCancellationRequested(); window.Start(history);
        }
        catch (Exception error) when (error is not OperationCanceledException && !ct.IsCancellationRequested)
        {
            if (historyWindow == window) historyError = "请检查连接后重试。" + error.Message;
            return;
        }
        finally { if (historyWindow == window) { historyLoading = false; UpdateHistoryButtons(); UpdateChatState(); } }
        await RenderMessages();
        ct.ThrowIfCancellationRequested();
        if (Messages.Items.Count > 0)
        {
            var target = anchor.HasValue ? Messages.Items.OfType<TimelineEntry>().FirstOrDefault(x => x.Message?.Seq == anchor) : null;
            if (target is not null) Messages.ScrollIntoView(target); else QueueScrollToLatest();
        }
        var currentSync = session;
        // 历史页先展示；补增量可能排在其他群之后，不能阻塞当前会话首屏。
        _ = Guard(async () =>
        {
            await currentSync.LoadChatAsync(chat, ct);
            ct.ThrowIfCancellationRequested();
            if (!anchor.HasValue && await session.Repository.GetLatestHistoryAsync(chat, ct) is null)
            {
                var fresh = await session.GetHistoryAsync(new() { ChatId = chat, Direction = HistoryDirection.Older, Limit = 60 }, ct);
                ct.ThrowIfCancellationRequested(); window.Start(fresh);
            }
        });
        await UpdateActiveChat();
        ScheduleRead();
    }
    private Task RenderMessages()
    {
        timelineRenderRevision++;
        return timelineRenderTask ??= RenderTimelineLoopAsync();
    }
    private async Task RenderTimelineLoopAsync()
    {
        // 先让调用方登记任务；同一轮中的重复刷新只保留最后的窗口查询。
        await Task.Yield();
        try
        {
            long revision;
            do
            {
                revision = timelineRenderRevision;
                try { await RenderTimelineSnapshotAsync(revision); }
                catch (OperationCanceledException) { }
            } while (revision != timelineRenderRevision);
        }
        finally { timelineRenderTask = null; }
    }
    private async Task RenderTimelineSnapshotAsync(long revision)
    {
        var session = runtime; var currentWindow = historyWindow; long chat = selectedChat;
        if (session is null || currentWindow is null || chat == 0) return;
        var ct = pageTask?.Token ?? lifetime.Token;
        var snapshot = await session.Repository.GetTimelineAsync(currentWindow.Capture(chat), ct);
        ct.ThrowIfCancellationRequested();
        if (session != runtime || currentWindow != historyWindow || chat != selectedChat || revision != timelineRenderRevision) return;
        var messages = snapshot.Messages; var events = snapshot.Events;
        var pendingEntries = snapshot.Pending; var outboxEntries = snapshot.Outbox;
        string signature = selectedChat + ":" + string.Join('.', session.OwnUsers) + ":" + string.Join(',', messages.Select(m => $"{m.Seq}.{m.Version}")) + "/" + string.Join(',', events.Select(e => $"{e.Id}.{e.Version}")) + "/" + string.Join(',', pendingEntries.Select(p => p.ClientRandomId)) + "/" + string.Join(',', outboxEntries.Select(o => $"{o.ClientRandomId}.{o.Pts}"));
        if (signature == messageSignature) { UpdateChatState(); return; }
        messageSignature = signature;
        var scroll = Descendant<ScrollViewer>(Messages);
        bool followBottom = historyWindow?.FollowsLatest == true && Messages.Items.Count > 0
            && scroll is not null && scroll.ScrollableHeight - scroll.VerticalOffset < 40;
        var desired = new List<TimelineEntry>();
        var retained = new Dictionary<string, TimelineEntry>();
        TimelineEntry Retain(string key, object value)
        {
            var view = messageViews.GetValueOrDefault(key) ?? new TimelineEntry(key, value);
            retained[key] = view; return view;
        }
        var ordered = messages.Select(m => (Time: m.Time, Value: (object)m)).Concat(events.Select(e => (Time: e.Time, Value: (object)e))).OrderBy(x => x.Time).ToList();
        bool group = dialogIndex.GetValueOrDefault(chat)?.Scene == Scene.Group;
        var layout = ChatPresentation.Layout(ordered.Select(x => x.Value is ProtoMessage pm
            ? new ChatPresentation.TimelineItem(pm.Time, pm.SenderId, pm.Kind != MessageKind.Service)
            : new ChatPresentation.TimelineItem(x.Time, 0, false)).ToList(), group, session.OwnUsers);
        timelineMessages = messages.GroupBy(m => m.Seq).ToDictionary(g => g.Key, g => g.Last());
        for (int i = 0; i < ordered.Count; i++)
        {
            if (layout[i].ShowsTime) desired.Add(Retain($"h:{ordered[i].Time}", new TimeHeader(ordered[i].Time)));
            if (ordered[i].Value is ProtoMessage m) desired.Add(Retain($"m:{m.ChatId}:{m.Seq}:{m.Version}:{(layout[i].ShowsSender ? 1 : 0)}:{(session.OwnUsers.Contains(m.SenderId) ? 1 : 0)}", new MessageItem(m, layout[i].ShowsSender)));
            else if (ordered[i].Value is ChatEvent e) desired.Add(Retain($"e:{e.ChatId}:{e.Id}:{e.Version}", e));
        }
        foreach (var pending in pendingEntries.Where(p => !outboxEntries.Any(o => o.ClientRandomId == p.ClientRandomId)))
        {
            var retry = new HyperlinkButton { Content = "重试", Padding = new Thickness(4, 0, 4, 0) };
            retry.Click += async (_, _) => await Guard(() => Submit(pending));
            desired.Add(new TimelineEntry("pending:" + desired.Count, PendingBubble(OutgoingPreview(pending.Segments), "未确认发送", false, retry)));
        }
        foreach (var o in outboxEntries.Where(o => o.State != OutboxState.Sent))
        {
            FrameworkElement? action = null;
            if (o.State == OutboxState.Failed && o.Segments.Any(s => s.KindCase == OutgoingSegment.KindOneofCase.Forward))
                action = new TextBlock { Text = "请从原消息重新转发", Style = (Style)Microsoft.UI.Xaml.Application.Current.Resources["CaptionTextBlockStyle"] };
            else if (o.State == OutboxState.Failed)
            {
                var retry = new HyperlinkButton { Content = "重试", Padding = new Thickness(4, 0, 4, 0) };
                retry.Click += async (_, _) => await Guard(() => { var r = new SendMessageRequest { ChatId = o.ChatId, ClientRandomId = o.ClientRandomId, ReplyToSeq = o.ReplyToSeq }; r.Segments.Add(o.Segments); return Submit(r); });
                action = retry;
            }
            desired.Add(new TimelineEntry("pending:" + desired.Count, PendingBubble(OutgoingPreview(o.Segments),
                o.State == OutboxState.Failed ? "发送失败：" + o.Error : "等待 QQ 发送…", o.State == OutboxState.Failed, action)));
        }
        // 保留未变化的行和容器，让 ItemsStackPanel 维持阅读锚点，避免每次推送清空整个列表。
        var wanted = desired.ToHashSet();
        for (int i = Messages.Items.Count - 1; i >= 0; i--)
            if (Messages.Items[i] is not TimelineEntry row || !wanted.Contains(row)) Messages.Items.RemoveAt(i);
        for (int i = 0; i < desired.Count; i++)
        {
            if (i < Messages.Items.Count && ReferenceEquals(Messages.Items[i], desired[i])) continue;
            int existing = Messages.Items.IndexOf(desired[i]);
            if (existing >= 0) Messages.Items.RemoveAt(existing);
            Messages.Items.Insert(i, desired[i]);
        }
        messageViews = retained;
        UpdateChatState();
        // 回复条要等时间线加载后才能拿到原消息的发送者和内容。
        if (replySeq > 0) UpdateReply();
        if (followBottom && desired.Count > 0)
        {
            var window = historyWindow; var last = desired[^1];
            DispatcherQueue.TryEnqueue(() => { if (historyWindow == window && Messages.Items.Contains(last)) Messages.ScrollIntoView(last); });
        }
        // 内容还不够一屏时滚动事件不会触发，渲染完也检查一次是否要接着往上加载。
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, CheckAutoLoad);
    }
    private static T? Descendant<T>(DependencyObject parent) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match) return match;
            if (Descendant<T>(child) is { } nested) return nested;
        }
        return null;
    }
    private string EventText(ChatEvent e) => ChatPresentation.EventText(e.Kind, e.DataJson,
        e.ActorId == 0 ? "" : PeerName(e.ActorId, Scene.Friend), e.TargetId == 0 ? "" : PeerName(e.TargetId, Scene.Friend), e.ActorId == e.TargetId);
    private void MessageSizeChanged(object sender, SizeChangedEventArgs args) => QueueScrollToLatest();
    private void QueueScrollToLatest()
    {
        if (!followLatest || scrollQueued || Messages.Items.Count == 0 || ChatPanel.Visibility != Visibility.Visible) return;
        scrollQueued = true;
        var window = historyWindow;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            scrollQueued = false;
            if (!followLatest || historyWindow != window || Messages.Items.Count == 0) return;
            Messages.ScrollIntoView(Messages.Items[^1]);
            Messages.UpdateLayout();
            var scroll = Descendant<ScrollViewer>(Messages);
            scroll?.ChangeView(null, scroll.ScrollableHeight, null, true);
        });
    }
    private void MessageContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer.ContentTemplateRoot is not ContentControl host) return;
        if (args.InRecycleQueue) { host.Content = null; return; }
        if (args.Item is not TimelineEntry row) return;
        host.Content = row.Value switch
        {
            MessageItem item => MessageView(item.Message, showSender: item.ShowsSender),
            TimeHeader header => TimeHeaderView(header.Time),
            ChatEvent e => EventNotice(e),
            FrameworkElement view => view,
            _ => null
        };
        args.Handled = true;
    }
    private static MediaInfo? Media(Segment s) => s.Image?.Media ?? s.Record?.Media ?? s.Video?.Media ?? s.File?.Media ?? s.MarketFace?.Media;
    private async Task DialogBox(string title, UIElement content) => await new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = content, CloseButtonText = "关闭", DefaultButton = ContentDialogButton.Close }.ShowAsync();
    // 回复条：「回复 某人」+ 原文一行；原消息不在当前窗口时只写序号。
    private void UpdateReply()
    {
        ReplyBar.Visibility = replySeq > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (replySeq <= 0) return;
        if (timelineMessages.TryGetValue(replySeq, out var target) && target.ChatId == selectedChat)
        {
            ReplyLabel.Text = "回复 " + SenderDisplay(target);
            ReplyPreview.Text = (target.Text.Length > 0 ? target.Text : "[消息]").Replace('\n', ' ');
        }
        else { ReplyLabel.Text = "回复消息"; ReplyPreview.Text = "#" + replySeq; }
    }
    private void ClearReply(object sender, RoutedEventArgs e) { replySeq = 0; replies[selectedChat] = 0; dirtyDrafts.Add(selectedChat); UpdateReply(); draftTimer.Start(); }
    private async void DraftChanged(object sender, TextChangedEventArgs e)
    {
        if (rendering || selectedChat == 0) return;
        CurrentDocument().UpdateText(Composer.Text); dirtyDrafts.Add(selectedChat); draftTimer.Stop(); draftTimer.Start();
        if (windowActive && runtime is { } session)
        {
            long chat = selectedChat; var ct = lifetime.Token;
            await Guard(() => session.SetTypingAsync(chat, ct));
        }
    }
    private async Task SaveDraft()
    {
        if (runtime is null || selectedChat == 0 || !dirtyDrafts.Remove(selectedChat)) return;
        var request = new SaveDraftRequest { ChatId = selectedChat, ReplyToSeq = replySeq };
        request.Segments.Add(CurrentDocument().Segments());
        replies[selectedChat] = replySeq;
        var session = runtime; var ct = lifetime.Token;
        draftTimer.Stop();
        try { await session.SaveDraftAsync(request, ct); }
        catch { if (runtime == session) dirtyDrafts.Add(request.ChatId); throw; }
    }
    private async void SendClicked(object sender, RoutedEventArgs e) => await Guard(SendAll);
    private async void ComposerKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) return;
        e.Handled = true; await Guard(SendAll);
    }
    private async Task SendText()
    {
        if (runtime is null || selectedChat == 0 || sending || string.IsNullOrWhiteSpace(Composer.Text)) return;
        sending = true; SendButton.IsEnabled = false;
        var r = new SendMessageRequest { ChatId = selectedChat, ClientRandomId = RandomId(), ReplyToSeq = replySeq };
        r.Segments.Add(CurrentDocument().Segments());
        var session = runtime; var ct = lifetime.Token;
        try
        {
            await session.QueueMessageAsync(r, ct);
            ct.ThrowIfCancellationRequested();
            if (runtime != session) return;
            if (selectedChat == r.ChatId && replySeq == r.ReplyToSeq && r.Segments.SequenceEqual(CurrentDocument().Segments()))
            { Composer.Text = ""; replySeq = 0; UpdateReply(); }
            await Submit(r); await SaveDraft();
        }
        finally { sending = false; SendButton.IsEnabled = true; }
    }
    private static long RandomId() => BetterChat.Application.MessageIdentity.Create();
    private async Task Submit(SendMessageRequest request)
    {
        var session = runtime; if (session is null) return;
        // 发送状态由时间线里的气泡显示（发送中 / 失败可重试），不再每条都弹底部提示（2026-10-17 实测会一直占着底部）。
        await session.SendMessageAsync(request, lifetime.Token);
    }
    // 「回到最新」：历史窗口本来就跟着最新时只滚到底；从搜索 / 引用跳进来的窗口要重新打开最新一页。
    private async void ReturnToLatest(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (historyWindow?.FollowsLatest == true)
        {
            followLatest = true; QueueScrollToLatest(); return;
        }
        await GoRoot(ChatKey(selectedChat), () => OpenChat(selectedChat));
    });
    private void UpdateHistoryButtons()
    {
        HistoryLoadingBar.Visibility = historyLoading && Messages.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateFloatingButtons();
    }
    private async Task LoadHistoryPage(bool older)
    {
        if (runtime is null || historyWindow is not { } window || historyLoading) return;
        if (!window.Initialized) { await OpenChat(selectedChat, historyAnchor); return; }
        long chat = selectedChat; var ct = pageTask?.Token ?? lifetime.Token;
        var anchor = older ? window.First : window.Last;
        if (!anchor.HasValue) return;
        var req = new GetHistoryRequest { ChatId = chat, Direction = older ? HistoryDirection.Older : HistoryDirection.Newer, Limit = 60, AnchorSeq = anchor.Value };
        followLatest = false; historyLoading = true; UpdateHistoryButtons();
        try
        {
            var page = await runtime.GetHistoryAsync(req, ct); ct.ThrowIfCancellationRequested();
            window.Extend(page, older);
            if (page.Messages.Count == 0) ContentSubtitle.Text = older ? "已到最早的存档消息" : "已到最新的存档消息";
        }
        finally { if (historyWindow == window) { historyLoading = false; UpdateHistoryButtons(); } }
    }
    private async Task ShowMedia(ProtoMessage message, MediaInfo media, string label)
    {
        if (api is null) return;
        var sessionApi = api;
        var ct = pageTask?.Token ?? lifetime.Token;
        media = await SessionFor(sessionApi).PrepareMediaForOpenAsync(message.ChatId, message.Seq, media, ct);
        string sha = media.State == MediaState.Stored ? MediaPresentation.OpenHash(media) : "";
        if (sha.Length == 0 && media.Mime.StartsWith("image/")) sha = MediaPresentation.PreviewHash(media);
        if (sha.Length == 0) throw new IOException("媒体暂不可用：" + media.State);
        var uri = await MediaUri(sessionApi, sha, ct);
        ct.ThrowIfCancellationRequested();
        if (api != sessionApi) return;
        if (media.Mime.StartsWith("image/")) await DialogBox(label, new Image { Source = new BitmapImage(uri), MaxWidth = 800, MaxHeight = 600, Stretch = Stretch.Uniform });
        else if (media.Mime.StartsWith("audio/") || media.Mime.StartsWith("video/"))
        {
            var player = new MediaPlayerElement { AreTransportControlsEnabled = true, AutoPlay = false, MaxWidth = 800, Height = media.Mime.StartsWith("audio/") ? 100 : 450, Source = Windows.Media.Core.MediaSource.CreateFromUri(uri) };
            try { await DialogBox(label, player); } finally { player.MediaPlayer?.Pause(); player.Source = null; }
        }
        else await Launcher.LaunchUriAsync(uri);
    }
    private async Task Forward(ClientSessionRuntime session, long fromChat, IReadOnlyList<long> sequences, bool bundled = false)
    {
        if (runtime != session || sequences.Count is < 1 or > 100) return;
        var ct = lifetime.Token;
        var dialogs = await session.Repository.GetDialogsAsync(ct);
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        var options = new ListView { ItemsSource = dialogs.Select(d => new ListEntry(PeerName(d.PeerId, d.Scene), "", "", d)).ToList(), DisplayMemberPath = "Title", MinWidth = 280, Height = 320, SelectionMode = ListViewSelectionMode.Multiple };
        var bundle = new CheckBox { Content = "合并为聊天记录", IsChecked = bundled };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(options); panel.Children.Add(bundle);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "转发到（最多 20 个会话）", Content = panel, PrimaryButtonText = "转发", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        options.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = options.SelectedItems.Count is > 0 and <= 20;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || runtime != session) return;
        ct.ThrowIfCancellationRequested();
        var r = new ForwardMessagesRequest { FromChatId = fromChat, Bundle = bundle.IsChecked == true };
        r.Seqs.AddRange(sequences);
        r.ToChatIds.AddRange(options.SelectedItems.Cast<ListEntry>().Select(x => ((Dialog)x.Value).ChatId));
        await using var vm = new ForwardMessagesViewModel(session.ForwardMessagesAsync, new UiDispatcher(DispatcherQueue));
        if (!await vm.SendAsync(r, ct) && runtime == session && !ct.IsCancellationRequested)
            throw new IOException((vm.Send.Error ?? "转发未完成。") + (vm.Send.OutcomeUncertain ? " 结果尚待确认，请先检查目标会话，避免重复转发。" : ""));
    }
}
