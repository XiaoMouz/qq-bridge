using System.Collections.ObjectModel;
using System.Security.Cryptography;
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

public sealed class ListEntry(string title, string subtitle, string badge, object value) : System.ComponentModel.INotifyPropertyChanged
{
    public string Title { get; private set; } = SingleLine(title);
    public string Subtitle { get; private set; } = SingleLine(subtitle);
    public string Badge { get; private set; } = badge;
    public object Value { get; private set; } = value;
    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    public string Key => Value switch { Dialog d => "d:" + d.ChatId, Peer p => $"p:{p.QqAccountId}:{p.Kind}:{p.PeerId}", _ => Title };
    public void Update(ListEntry next)
    {
        Value = next.Value;
        if (Title != next.Title) { Title = next.Title; PropertyChanged?.Invoke(this, new(nameof(Title))); }
        if (Subtitle != next.Subtitle) { Subtitle = next.Subtitle; PropertyChanged?.Invoke(this, new(nameof(Subtitle))); }
        if (Badge != next.Badge) { Badge = next.Badge; PropertyChanged?.Invoke(this, new(nameof(Badge))); }
    }
    private static string SingleLine(string text) => text.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
    public override string ToString() => Title;
}

public sealed record TimelineEntry(string Key, object Value)
{
    public override string ToString() => Value switch { ProtoMessage m => m.SenderName + "：" + m.Text, ChatEvent => "系统事件", _ => "发送中的消息" };
}

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

    public MainWindow()
    {
        InitializeComponent();
        InitializeNotifications();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        InitializeChatState();
        refreshTimer.Tick += (_, _) => { refreshTimer.Stop(); Interlocked.Exchange(ref refreshQueued, 0); RefreshList(); if (selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible) _ = Guard(RenderMessages); };
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
    }

    private async Task Guard(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception e) { Notice.Severity = InfoBarSeverity.Error; Notice.Message = e.Message; Notice.IsOpen = true; }
    }
    private CancellationToken NewPage()
    {
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
        ChatPanel.Visibility = ComposerPanel.Visibility = ChatMore.Visibility = Visibility.Collapsed;
        _ = UpdateActiveChat();
        DetailScroll.Visibility = Visibility.Visible; Details.Children.Clear();
    }
    private void ShowWelcome()
    {
        Workspace.Visibility = Visibility.Collapsed; Search.Visibility = Visibility.Collapsed;
        Onboarding.Visibility = Visibility.Visible;
        AccountAvatar.Visibility = Visibility.Collapsed;
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
        activeTimer.Start(); Rail.SelectedIndex = 0; RefreshList();
        Detail("选择一个会话", "消息和联系人正在同步，断线时仍可浏览已缓存的消息。");
        var account = accountState.QqAccounts.FirstOrDefault();
        if (account is not null)
        {
            AccountAvatar.DisplayName = account.Nickname.Length > 0 ? account.Nickname : account.Uin.ToString();
            AccountAvatar.Visibility = Visibility.Visible;
            ToolTipService.SetToolTip(AccountAvatar, AccountAvatar.DisplayName);
            _ = LoadAccountAvatar(candidate, account.Uin, sessionToken);
        }
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
            AccountAvatar.ProfilePicture = null; AccountAvatar.DisplayName = ""; AccountAvatar.Visibility = Visibility.Collapsed;
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
    private static string DisplayName(Peer p) => !string.IsNullOrWhiteSpace(p.Remark) ? p.Remark : !string.IsNullOrWhiteSpace(p.Name) ? p.Name : p.PeerId.ToString();
    private void RefreshList()
    {
        if (!ready || section == "search") return;
        string signature = $"{section}:{Filter.SelectedIndex}:{store?.DialogRevision}:{store?.PeerRevision}:{contactRevision}:{contactCategoryId}";
        if (signature == listSignature) return;
        listSignature = signature;
        rendering = true;
        var next = new List<ListEntry>();
        if (section == "messages" && store is not null)
        {
            var rows = runtime?.Dialogs.Items.ToArray() ?? [];
            dialogIndex = rows.ToDictionary(r => r.ChatId, r => r.Snapshot);
            var names = rows.ToDictionary(r => r.ChatId, r => r.Title);
            foreach (var d in dialogIndex.Values.Where(d => Filter.SelectedIndex == 2 ? d.NotifyPolicy == "archived" : d.NotifyPolicy != "archived").Where(d => Filter.SelectedIndex != 1 || d.UnreadCount > 0))
                next.Add(new(names[d.ChatId], d.Draft is { Segments.Count: > 0 } ? "草稿 · " + OutgoingPreview(d.Draft.Segments) : d.TopMessage?.Text ?? "暂无消息", (d.Pinned ? "置顶 " : "") + (d.UnreadCount > 0 ? d.UnreadCount.ToString() : ""), d));

        }
        else if (section == "contacts" && store is not null)
        {
            var directory = runtime!.Contacts.Directory;
            IEnumerable<Peer> peers = Filter.SelectedIndex == 0 ? directory.Friends : directory.Groups;
            if (Filter.SelectedIndex == 0 && contactCategoryId is { } categoryId)
            {
                var users = directory.Categories.FirstOrDefault(c => c.Id == categoryId)?.UserIds.ToHashSet() ?? [];
                peers = peers.Where(p => users.Contains(p.PeerId));
            }
            foreach (var p in peers.OrderBy(DisplayName))
                next.Add(new(DisplayName(p), p.Kind == PeerKind.Group ? $"{p.MemberCount} 位成员" : p.Sign, "", p));
        }
        else if (section == "settings")
        {
            foreach (var (title, sub) in new[] { ("连接与账号", "账号与登录状态"), ("外观", "主题与阅读体验"), ("设备", "已连接的设备"), ("存储", "服务端空间与缓存"), ("服务端状态", "QQ、队列与通话桥"), ("存档完整性", "消息缺口与深度归档"), ("通话记录", "最近的 QQ 通话"), ("关于", "BetterChat for Windows") })
                next.Add(new(title, sub, "", title));
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
    private void RailChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || Rail.SelectedItem is not ListViewItem item) return;
        _ = Guard(SaveDraft); NewPage(); selectedChat = 0;
        section = (string)item.Tag; SectionTitle.Text = section == "messages" ? "消息" : section == "contacts" ? "联系人" : "设置";
        MoreSearchResults.Visibility = Visibility.Collapsed;
        rendering = true; Filter.Items.Clear();
        foreach (string s in section == "messages" ? new[] { "全部消息", "未读", "群助手" } : section == "contacts" ? new[] { "好友", "群聊" } : Array.Empty<string>()) Filter.Items.Add(new ComboBoxItem { Content = s });
        Filter.Visibility = section == "settings" ? Visibility.Collapsed : Visibility.Visible;
        Filter.SelectedIndex = 0; rendering = false; RefreshList();
        if (section == "settings") ShowConnection();
        else if (api is null) ShowWelcome();
        else if (section == "contacts")
        {
            contactCategoryId = null; ShowContactsOverview();
            _ = Guard(() => runtime!.Contacts.LoadAsync(ct: lifetime.Token));
        }
        else Detail("选择一个会话", "从左侧列表继续");
    }
    private void FilterChanged(object sender, SelectionChangedEventArgs e) { if (!rendering) RefreshList(); }
    private async void ItemSelected(object sender, SelectionChangedEventArgs e)
    {
        if (rendering || Items.SelectedItem is not ListEntry entry) return;
        await Guard(async () =>
        {
            if (entry.Value is Dialog d) await OpenChat(d.ChatId);
            else if (entry.Value is ProtoMessage m) await OpenChat(m.ChatId, m.Seq);
            else if (entry.Value is Peer p) { _ = Guard(SaveDraft); NewPage(); selectedChat = 0; ShowProfile(p); }
            else if (entry.Value is string s) { NewPage(); await ShowSetting(s); }
        });
    }
    private async Task OpenChat(long chat, long? anchor = null)
    {
        if (api is null || store is null || runtime is null) return;
        var session = runtime;
        _ = Guard(SaveDraft); var ct = NewPage(); selectedChat = chat; messageSignature = "";
        var window = new HistoryWindow(!anchor.HasValue); historyWindow = window; followLatest = !anchor.HasValue;
        historyError = ""; readTimer.Stop();
        historyAnchor = anchor; messageViews.Clear(); Messages.Items.Clear();
        historyLoading = true; UpdateHistoryButtons();
        var d = dialogIndex.GetValueOrDefault(chat);
        var localDraft = await session.Repository.GetLocalDraftAsync(chat, ct);
        ct.ThrowIfCancellationRequested();
        if (localDraft is not null) dirtyDrafts.Add(chat);
        ContentTitle.Text = d is null ? "聊天" : PeerName(d.PeerId, d.Scene);
        ContentSubtitle.Text = d?.Scene == Scene.Group ? "群聊" : "私聊";
        DetailScroll.Visibility = Visibility.Collapsed;
        ChatPanel.Visibility = ComposerPanel.Visibility = ChatMore.Visibility = Visibility.Visible;
        rendering = true;
        if (!drafts.TryGetValue(chat, out var document))
        {
            document = ComposerDocument.FromSegments(localDraft?.Segments.AsEnumerable() ?? d?.Draft?.Segments.AsEnumerable() ?? [], id => PeerName(id, Scene.Friend));
            drafts[chat] = document;
        }
        Composer.Text = document.Text;
        MentionButton.Visibility = d?.Scene == Scene.Group ? Visibility.Visible : Visibility.Collapsed;
        replySeq = replies.GetValueOrDefault(chat, localDraft?.ReplyToSeq ?? d?.Draft?.ReplyToSeq ?? 0); UpdateReply(); rendering = false;
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
            var target = anchor.HasValue ? Messages.Items.OfType<TimelineEntry>().FirstOrDefault(x => x.Value is ProtoMessage m && m.Seq == anchor) : null;
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
        string signature = selectedChat + ":" + string.Join(',', messages.Select(m => $"{m.Seq}.{m.Version}")) + "/" + string.Join(',', events.Select(e => $"{e.Id}.{e.Version}")) + "/" + string.Join(',', pendingEntries.Select(p => p.ClientRandomId)) + "/" + string.Join(',', outboxEntries.Select(o => $"{o.ClientRandomId}.{o.Pts}"));
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
        foreach (var entry in messages.Select(m => (Time: m.Time, Value: (object)m)).Concat(events.Select(e => (Time: e.Time, Value: (object)e))).OrderBy(x => x.Time))
        {
            if (entry.Value is ProtoMessage m) desired.Add(Retain($"m:{m.ChatId}:{m.Seq}:{m.Version}", m));
            else if (entry.Value is ChatEvent e) desired.Add(Retain($"e:{e.ChatId}:{e.Id}:{e.Version}", e));
        }
        foreach (var pending in pendingEntries.Where(p => !outboxEntries.Any(o => o.ClientRandomId == p.ClientRandomId)))
        {
            var panel = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(8) };
            panel.Children.Add(Text(OutgoingPreview(pending.Segments)));
            panel.Children.Add(ActionButton("未确认发送 · 重试", () => Submit(pending)));
            desired.Add(new TimelineEntry("pending:" + desired.Count, panel));
        }
        foreach (var o in outboxEntries.Where(o => o.State != OutboxState.Sent))
        {
            var panel = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(8) };
            panel.Children.Add(Text(OutgoingPreview(o.Segments)));
            panel.Children.Add(Text(o.State == OutboxState.Failed ? "发送失败：" + o.Error : "等待 QQ 发送…", 12));
            if (o.State == OutboxState.Failed)
            {
                if (o.Segments.Any(s => s.KindCase == OutgoingSegment.KindOneofCase.Forward))
                    panel.Children.Add(Text("合并转发失败，请从原消息重新选择转发。", 12));
                else panel.Children.Add(ActionButton("重试", () => { var r = new SendMessageRequest { ChatId = o.ChatId, ClientRandomId = o.ClientRandomId, ReplyToSeq = o.ReplyToSeq }; r.Segments.Add(o.Segments); return Submit(r); }));
            }
            desired.Add(new TimelineEntry("pending:" + desired.Count, panel));
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
        if (followBottom && desired.Count > 0)
        {
            var window = historyWindow; var last = desired[^1];
            DispatcherQueue.TryEnqueue(() => { if (historyWindow == window && Messages.Items.Contains(last)) Messages.ScrollIntoView(last); });
        }
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
    private static string EventText(ChatEvent e)
    {
        try { using var doc = System.Text.Json.JsonDocument.Parse(e.DataJson); if (doc.RootElement.TryGetProperty("text", out var t) && t.ValueKind == System.Text.Json.JsonValueKind.String) return t.GetString() ?? "系统事件"; }
        catch (System.Text.Json.JsonException) { }
        return e.Kind switch { "member_join" => "有新成员加入群聊", "member_leave" => "有成员离开群聊", "poke" => "戳一戳", "group_file" => "有新的群文件", "group_name" => "群名称已更新", "essence_add" => "消息被设为精华", _ => "群聊动态" };
    }
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
            ProtoMessage m => MessageView(m),
            ChatEvent e => new TextBlock { Text = EventText(e), TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(12), FontSize = 12 },
            FrameworkElement view => view,
            _ => null
        };
        args.Handled = true;
    }
    private FrameworkElement MessageView(ProtoMessage m, bool includeActions = true)
    {
        var owner = runtime;
        var pageToken = pageTask?.Token ?? lifetime.Token;
        Task OnOriginalPage(Func<Task> action) => owner is not null && runtime == owner && !pageToken.IsCancellationRequested ? action() : Task.CompletedTask;
        bool own = runtime?.OwnUsers.Contains(m.SenderId) == true;
        var body = new StackPanel { Spacing = 8, MaxWidth = 620 };
        body.Children.Add(Text((own ? "你" : string.IsNullOrEmpty(m.SenderName) ? m.SenderId.ToString() : m.SenderName) + "  ·  " + DateTimeOffset.FromUnixTimeSeconds(m.Time).ToLocalTime().ToString("MM-dd HH:mm"), 11));
        if (m.ReplyToSeq > 0) body.Children.Add(ActionButton($"回复 #{m.ReplyToSeq}", () => OnOriginalPage(() => OpenChat(m.ChatId, m.ReplyToSeq))));
        Microsoft.UI.Xaml.Documents.Paragraph? paragraph = null;
        void Inline(Microsoft.UI.Xaml.Documents.Inline content)
        {
            if (paragraph is null)
            {
                paragraph = new Microsoft.UI.Xaml.Documents.Paragraph();
                var rich = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 14 };
                rich.Blocks.Add(paragraph); body.Children.Add(rich);
            }
            paragraph.Inlines.Add(content);
        }
        foreach (var s in m.Segments)
        {
            if (s.Text is null && s.Mention is null && s.MentionAll is null && s.Face is null) paragraph = null;
            if (s.Text is { } t) Inline(new Microsoft.UI.Xaml.Documents.Run { Text = t.Text });
            else if (s.Mention is { } at) Inline(new Microsoft.UI.Xaml.Documents.Run { Text = "@" + (at.Name.Length > 0 ? at.Name : at.UserId.ToString()), Foreground = (Brush)Microsoft.UI.Xaml.Application.Current.Resources["AccentTextFillColorPrimaryBrush"] });
            else if (s.MentionAll is not null) Inline(new Microsoft.UI.Xaml.Documents.Run { Text = "@全体成员" });
            else if (s.Face is { } f)
            {
                if (FaceImage(f.FaceId) is { } picture) Inline(new Microsoft.UI.Xaml.Documents.InlineUIContainer { Child = picture });
                else Inline(new Microsoft.UI.Xaml.Documents.Run { Text = "[" + (f.Name.Length > 0 ? f.Name : "表情 " + f.FaceId) + "]" });
            }
            else if (s.Markdown is { } markdown) body.Children.Add(Text(markdown.Content));
            else if (Media(s) is { } media)
            {
                string label = s.File?.Name ?? (s.Image is not null ? "图片" : s.Record is not null ? $"语音 · {s.Record.DurationSec} 秒" : s.Video is not null ? "视频" : "表情");
                body.Children.Add(MediaPreview(m, s, media, label));
            }
            else if (s.Forward is not null) body.Children.Add(ActionButton("聊天记录 · " + s.Forward.Title, () => OnOriginalPage(() => ShowForward(m))));
            else if (s.Reply is null) body.Children.Add(Text(m.Text.Length > 0 ? m.Text : "[暂不支持的消息类型]"));
        }
        if (m.Segments.Count == 0) body.Children.Add(Text(m.Text));
        if (m.State == MessageState.Recalled) body.Children.Add(Text("此消息已撤回", 11));
        if (m.Reactions.Count > 0) body.Children.Add(Text(string.Join("  ", m.Reactions.Select(r => $"{r.EmojiId} × {r.Count}")), 12));
        var bubble = new Border { Child = body, Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(10), Margin = new Thickness(0, 6, 0, 6), HorizontalAlignment = m.Kind == MessageKind.Service ? HorizontalAlignment.Center : own ? HorizontalAlignment.Right : HorizontalAlignment.Left, Background = (Brush)Microsoft.UI.Xaml.Application.Current.Resources[own ? "SubtleFillColorSecondaryBrush" : "CardBackgroundFillColorDefaultBrush"], Tag = m };
        if (!includeActions) return bubble;
        var menu = new MenuFlyout();
        void Add(string label, Func<Task> action) { var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await Guard(() => OnOriginalPage(action)); menu.Items.Add(item); }
        Add("回复", () =>
        {
            if (selectedChat != m.ChatId) return Task.CompletedTask;
            replySeq = m.Seq; replies[m.ChatId] = replySeq; dirtyDrafts.Add(m.ChatId); draftTimer.Start(); UpdateReply(); Composer.Focus(FocusState.Keyboard); return Task.CompletedTask;
        });
        Add("复制", () => { var data = new DataPackage(); data.SetText(m.Text); Clipboard.SetContent(data); return Task.CompletedTask; });
        if (runtime is { } forwardingSession) Add("转发", () => Forward(forwardingSession, m.ChatId, [m.Seq]));
        if (runtime is { } stickerSession)
        {
            int index = 0;
            foreach (var segment in m.Segments.Where(s => s.Image is not null || s.MarketFace is not null))
            {
                var sha = Media(segment)?.Sha256;
                if (sha is { Length: 64 }) Add("收藏图片为表情 " + (++index), () => AddMessageSticker(sha, stickerSession));
            }
        }
        if (runtime is { } actionSession)
        {
            var actionToken = pageToken;
            async Task ChangeMessage(bool recall)
            {
                if (runtime != actionSession) return;
                await using var vm = new MessageActionsViewModel(m.ChatId, m.Seq, actionSession.RecallMessageAsync, actionSession.ReactAsync, new UiDispatcher(DispatcherQueue));
                bool succeeded = recall ? await vm.RecallAsync(actionToken)
                    : await vm.ReactAsync("128077", !m.Reactions.Any(r => r.EmojiId == "128077" && r.Me), actionToken);
                if (runtime != actionSession || actionToken.IsCancellationRequested || succeeded) return;
                string? error = recall ? vm.Recall.Error : vm.React.Error;
                bool uncertain = recall ? vm.Recall.OutcomeUncertain : vm.React.OutcomeUncertain;
                throw new IOException((error ?? "消息操作未完成。") + (uncertain ? " 请等待同步确认，避免重复操作。" : ""));
            }
            if (own && m.State == MessageState.Normal) Add("撤回", () => ChangeMessage(true));
            if (m.State == MessageState.Normal && dialogIndex.GetValueOrDefault(m.ChatId)?.Scene == Scene.Group)
                Add("回应 👍", () => ChangeMessage(false));
        }
            foreach (var reaction in m.Reactions)
                Add("查看回应 " + reaction.EmojiId + " 的用户", () => ShowReactionUsers(m, reaction.EmojiId));
        if (runtime is { } voiceSession && m.Segments.Any(s => s.Record is not null))
        {
            var voiceToken = pageToken;
            Add("语音转文字", async () =>
            {
                if (runtime != voiceSession) return;
                await using var operation = new RpcOperationViewModel<TranscribeVoiceRequest, TranscribeVoiceResponse>(voiceSession.TranscribeVoiceAsync, new UiDispatcher(DispatcherQueue), false);
                bool succeeded = await operation.ExecuteAsync(new() { ChatId = m.ChatId, Seq = m.Seq }, voiceToken);
                voiceToken.ThrowIfCancellationRequested();
                if (runtime != voiceSession) return;
                if (!succeeded) throw new IOException(operation.Error ?? "语音识别失败。");
                string text = operation.Result!.Text;
                await DialogBox("语音转文字", Text(text.Length > 0 ? text : "未识别出文字"));
            });
        }
        bubble.ContextFlyout = menu; return bubble;
    }
    private static MediaInfo? Media(Segment s) => s.Image?.Media ?? s.Record?.Media ?? s.Video?.Media ?? s.File?.Media ?? s.MarketFace?.Media;
    private async Task DialogBox(string title, UIElement content) => await new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = content, CloseButtonText = "关闭", DefaultButton = ContentDialogButton.Close }.ShowAsync();
    private void UpdateReply() { ReplyLabel.Text = replySeq > 0 ? $"回复消息 #{replySeq}" : ""; CancelReply.Visibility = replySeq > 0 ? Visibility.Visible : Visibility.Collapsed; }
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
    private async void SendClicked(object sender, RoutedEventArgs e) => await Guard(SendText);
    private async void ComposerKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) return;
        e.Handled = true; await Guard(SendText);
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
        var result = await session.SendMessageAsync(request, lifetime.Token);
        if (session != runtime) return;
        Notice.Severity = InfoBarSeverity.Informational; Notice.Message = result.Entry.State == OutboxState.Sent ? "消息已发送" : "消息已进入发送队列"; Notice.IsOpen = true;
    }
    private async void LoadOlder(object sender, RoutedEventArgs e) => await Guard(() => LoadHistoryPage(true));
    private async void LoadNewer(object sender, RoutedEventArgs e) => await Guard(() => LoadHistoryPage(false));
    private async void ReturnToLatest(object sender, RoutedEventArgs e) => await Guard(() => OpenChat(selectedChat));
    private void UpdateHistoryButtons()
    {
        OlderButton.IsEnabled = !historyLoading && historyWindow?.HasOlder == true;
        NewerButton.IsEnabled = !historyLoading && historyWindow?.HasNewer == true;
        NewerButton.Visibility = LatestButton.Visibility = historyWindow?.FollowsLatest == false ? Visibility.Visible : Visibility.Collapsed;
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
    private async void AttachFile(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        var session = runtime;
        if (session is null || selectedChat == 0) return;
        long chat = selectedChat; var ct = lifetime.Token;
        var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this)); picker.FileTypeFilter.Add("*");
        var file = await picker.PickSingleFileAsync();
        ct.ThrowIfCancellationRequested();
        if (file is null || runtime != session) return;
        var confirm = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "发送附件", Content = file.Name, PrimaryButtonText = "发送", CloseButtonText = "取消" };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        using var stream = await file.OpenStreamForReadAsync();
        var media = await session.UploadMediaAsync(stream, file.Name, file.ContentType, ct);
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        var request = new SendMessageRequest { ChatId = chat, ClientRandomId = RandomId() };
        request.Segments.Add(file.ContentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase) ? new OutgoingSegment { Image = media } : new OutgoingSegment { File = media });
        var result = await session.SendMessageAsync(request, ct);
        if (runtime != session) return;
        Notice.Severity = InfoBarSeverity.Informational; Notice.Message = result.Entry.State == OutboxState.Sent ? "附件已发送" : "附件已进入发送队列"; Notice.IsOpen = true;
    });
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
    private async Task Forward(ClientSessionRuntime session, long fromChat, IReadOnlyList<long> sequences)
    {
        if (runtime != session || sequences.Count is < 1 or > 100) return;
        var ct = lifetime.Token;
        var dialogs = await session.Repository.GetDialogsAsync(ct);
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        var options = new ListView { ItemsSource = dialogs.Select(d => new ListEntry(PeerName(d.PeerId, d.Scene), "", "", d)).ToList(), DisplayMemberPath = "Title", MinWidth = 280, Height = 320, SelectionMode = ListViewSelectionMode.Multiple };
        var bundle = new CheckBox { Content = "合并为聊天记录" };
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
