using BetterChat.Application.ViewModels;
using BetterChat.Application;
using BetterChat.Core;
using Qqbridge.V1;
using System.Threading.Channels;
using System.Security.Cryptography;

namespace BetterChat.Infrastructure;

// 账号作用域的组合根。先停止所有生产者并等回写结束，再关闭仓储、数据库和传输。
public sealed class ClientSessionRuntime : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly PreviewCache? previewCache;
    private readonly CancellationTokenSource lifetime = new();
    private readonly ConnectClient transport;
    private readonly LocalStore store;
    private readonly SyncEngine sync;
    private Task? running;
    private Task? closing;
    private readonly HashSet<Task> sessionTasks = [];
    private readonly HashSet<long> sendingIds = [];
    private readonly HashSet<(long Chat, long Seq)> changingMessages = [];
    private readonly HashSet<long> sendingVoiceChats = [];
    private readonly HashSet<long> typingChats = [];
    private readonly Dictionary<long, long> typingTimes = [];
    private Task draftTail = Task.CompletedTask;
    private readonly ActiveChatCoordinator activeChat;
    private readonly Channel<bool> dialogChanges = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
    {
        SingleReader = true, SingleWriter = false, FullMode = BoundedChannelFullMode.DropWrite,
        AllowSynchronousContinuations = false
    });
    public BridgeApi Api { get; }
    public ReadReceiptCoordinator ReadReceipts { get; }
    // 旧调试页面仍同步读写缓存；所有权始终属于运行时，宿主不得单独 Dispose。
    public ILocalStore LegacyStore => store;
    public IReadOnlySet<long> OwnUsers => sync.OwnUsers;
    public void SeedOwnUsers(IEnumerable<long> users) => sync.SeedOwnUsers(users);
    public LocalRepository Repository { get; }
    public ContactsViewModel Contacts { get; }
    public DialogListViewModel Dialogs { get; }
    public CallStateViewModel Calls { get; }
    public event Action<string>? ConnectionStatus;
    public event Action<long>? ChatInvalidated;
    public event Action<Message>? StreamMessageReceived;
    public event Action<SubscribeResponse>? Ephemeral;

    private ClientSessionRuntime(Uri server, string token, string databasePath, IUiDispatcher dispatcher, HttpMessageHandler? handler)
    {
        transport = new ConnectClient(server, handler) { Token = token };
        try { store = new LocalStore(databasePath); }
        catch { transport.Dispose(); throw; }
        Api = new BridgeApi(transport);
        ReadReceipts = new((chat, sequence, ct) => MarkReadAsync(new() { ChatId = chat, MaxSeq = sequence }, ct));
        activeChat = new((chat, ct) => Api.SetActiveChatAsync(new() { ChatId = chat }, ct));
        previewCache = databasePath == ":memory:" ? null : new PreviewCache(Path.GetFullPath(databasePath) + ".media");
        Repository = new LocalRepository(store);
        Contacts = new ContactsViewModel(Api, Repository, dispatcher, Repository);
        Dialogs = new DialogListViewModel(Repository, dispatcher);
        Calls = new CallStateViewModel(Api, dispatcher);
        sync = new SyncEngine(Api, store);
        sync.EphemeralReceived += ReceiveAsync;
        sync.Status += StatusChanged;
        sync.ChatInvalidated += InvalidateChat;
        sync.StreamMessageReceived += ReceiveMessage;
        store.DialogsChanged += QueueDialogs;
        store.PeersChanged += QueueDialogs;
    }

    public static Task<ClientSessionRuntime> CreateAsync(Uri server, string token, string databasePath,
        IUiDispatcher dispatcher, CancellationToken ct = default, HttpMessageHandler? handler = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(token);
        // SQLite 打开、迁移和 protobuf 同步逻辑不能从 WinUI 启动线程直接执行。
        return Task.Run(() => new ClientSessionRuntime(server, token, databasePath, dispatcher, handler), ct);
    }
    public void Start()
    {
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            running ??= Task.Run(RunAsync);
        }
    }
    public Task LoadChatAsync(long chatId, CancellationToken ct = default) => TrackAsync(async token =>
    {
        await sync.LoadChatAsync(chatId, token).ConfigureAwait(false);
        return true;
    }, ct);
    public Task<GetHistoryResponse> GetHistoryAsync(GetHistoryRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(async token =>
        {
            var page = await Api.GetHistoryAsync(copy, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            bool latest = !copy.HasAnchorSeq && copy.Direction == HistoryDirection.Older;
            await Repository.MergeHistoryPageAsync(copy.ChatId, page, latest, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            return page;
        }, ct);
    }
    public Task QueueMessageAsync(SendMessageRequest request, CancellationToken ct = default)
    {
        var copy = ValidateMessage(request);
        return TrackAsync(async token => { await Repository.SavePendingAsync(copy, token).ConfigureAwait(false); return true; }, ct);
    }
    public Task<Uri> GetPreviewUriAsync(string sha, CancellationToken ct = default) => TrackAsync(async token =>
    {
        if (previewCache is null) throw new InvalidOperationException("当前会话没有持久预览缓存目录。");
        string path = await previewCache.GetAsync(sha, async (output, cancel) =>
        {
            var request = new SignMediaUrlsRequest(); request.Sha256.Add(sha);
            var response = await Api.SignMediaUrlsAsync(request, cancel).ConfigureAwait(false);
            var signed = response.Urls.FirstOrDefault(u => u.Sha256.Equals(sha, StringComparison.OrdinalIgnoreCase));
            if (signed is null || string.IsNullOrWhiteSpace(signed.Url)) throw new IOException("服务器未返回预览地址。");
            await transport.DownloadPreviewAsync(signed.Url, output, cancel).ConfigureAwait(false);
        }, token).ConfigureAwait(false);
        return new Uri(path);
    }, ct);
    public Task<PreviewCacheUsage> GetPreviewCacheUsageAsync(CancellationToken ct = default) => TrackAsync(token =>
        previewCache?.GetUsageAsync(token) ?? Task.FromResult(new PreviewCacheUsage(0, 0, 0, 0)), ct);
    public Task<PreviewCacheCleanup> ClearPreviewCacheAsync(CancellationToken ct = default) => TrackAsync(token =>
        previewCache?.ClearAsync(token) ?? Task.FromResult(new PreviewCacheCleanup(0, 0, 0)), ct);
    public Task PersistDraftAsync(SaveDraftRequest request)
    {
        if (request.ChatId <= 0 || request.ReplyToSeq < 0) throw new ArgumentException("草稿会话或回复序号无效。", nameof(request));
        var copy = request.Clone();
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            var persisted = Repository.SaveLocalDraftAsync(copy);
            // 正常退出先排入本地写入，不依赖网络；账号取消不会丢掉已接受的草稿。
            return TrackAsync(async _ => { await persisted.ConfigureAwait(false); return true; }, CancellationToken.None);
        }
    }
    public Task SaveDraftAsync(SaveDraftRequest request, CancellationToken ct = default)
    {
        if (request.ChatId <= 0 || request.ReplyToSeq < 0) throw new ArgumentException("草稿会话或回复序号无效。", nameof(request));
        var copy = request.Clone();
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            ct.ThrowIfCancellationRequested();
            // 入库按调用顺序排队，不等待旧网络请求；退出前尚未发送的新内容也能恢复。
            var persisted = Repository.SaveLocalDraftAsync(copy);
            var previous = draftTail;
            var task = TrackAsync(async token =>
            {
                await persisted.ConfigureAwait(false);
                try { await previous.ConfigureAwait(false); } catch (Exception) { /* 旧保存失败不阻止保存新内容。 */ }
                token.ThrowIfCancellationRequested();
                await Api.SaveDraftAsync(copy, token).ConfigureAwait(false);
                await Repository.ConfirmLocalDraftAsync(copy.ChatId, CancellationToken.None).ConfigureAwait(false);
                return true;
            }, ct);
            draftTail = task;
            return task;
        }
    }
    public Task<OutgoingMedia> UploadMediaAsync(Stream source, string name, string mime, CancellationToken ct = default)
    {
        if (!source.CanRead || !source.CanSeek) throw new ArgumentException("上传需要可读取、可定位的文件流。", nameof(source));
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        return TrackAsync(async token =>
        {
            // 调用者持有文件流直到任务结束；从头计算哈希，续传偏移由服务器决定。
            source.Position = 0;
            long length = source.Length;
            string sha = Convert.ToHexString(await SHA256.HashDataAsync(source, token).ConfigureAwait(false)).ToLowerInvariant();
            token.ThrowIfCancellationRequested();
            if (source.Length != length) throw new IOException("文件大小在计算哈希期间发生变化。");
            var upload = await Api.PrepareUploadAsync(new() { Sha256 = sha, Size = (ulong)length,
                Name = name, Mime = string.IsNullOrWhiteSpace(mime) ? "application/octet-stream" : mime }, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            if (source.Length != length) throw new IOException("文件大小在准备上传期间发生变化，请重新选择文件。");
            if (!upload.Exists)
            {
                if (string.IsNullOrWhiteSpace(upload.UploadUrl) || upload.Offset > (ulong)length)
                    throw new IOException("上传准备返回了无效地址或偏移。");
                await transport.UploadAsync(upload.UploadUrl, source, (long)upload.Offset, token).ConfigureAwait(false);
            }
            token.ThrowIfCancellationRequested();
            return new OutgoingMedia { Sha256 = sha, Name = name };
        }, ct);
    }
    public Task<SendMessageResponse> SendMessageAsync(SendMessageRequest request, CancellationToken ct = default)
    {
        var copy = ValidateMessage(request);
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            if (!sendingIds.Add(copy.ClientRandomId)) throw new InvalidOperationException("此消息正在发送，请等待结果。");
            return TrackAsync(async token =>
            {
                try
                {
                    await Repository.SavePendingAsync(copy, token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    var response = await Api.SendMessageAsync(copy, token).ConfigureAwait(false);
                    if (response.Entry is not { } entry || entry.ClientRandomId != copy.ClientRandomId || entry.ChatId != copy.ChatId)
                        throw new IOException("发送确认与请求不匹配，保留待发送记录以便确认或重试。");
                    // 已收到确认必须落库，即使页面此刻取消；运行时会等这次回写完成才关库。
                    await Repository.AcceptPendingAsync(entry, CancellationToken.None).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    return response;
                }
                finally { lock (gate) sendingIds.Remove(copy.ClientRandomId); }
            }, ct);
        }
    }
    public Task<ForwardMessagesResponse> ForwardMessagesAsync(ForwardMessagesRequest request, CancellationToken ct = default)
    {
        var copy = ForwardValidation.Normalize(request);
        return TrackAsync(async token =>
        {
            var response = await Api.ForwardMessagesAsync(copy, token).ConfigureAwait(false);
            if (response.Entries.Any(e => !copy.ToChatIds.Contains(e.ChatId) || e.ClientRandomId <= 0))
                throw new IOException("转发确认包含无效目标或消息标识，请先检查同步结果。");
            // 原生逐条转发可以返回空列表；收到的发件箱确认仍需在取消后保存，不能推进全局游标。
            foreach (var entry in response.Entries)
                await Repository.AcceptPendingAsync(entry, CancellationToken.None).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            return response;
        }, ct);
    }
    public Task<GetUserProfileResponse> GetUserProfileAsync(GetUserProfileRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.UserId);
        return TrackAsync(token => Api.GetUserProfileAsync(copy, token), ct);
    }
    public Task<GetGroupProfileResponse> GetGroupProfileAsync(GetGroupProfileRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.GetGroupProfileAsync(copy, token), ct);
    }
    public Task<OpenChatResponse> OpenChatAsync(OpenChatRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.PeerId);
        if (copy.Scene is not (Scene.Friend or Scene.Group) || copy.ViaGroupId is < 0 or > 9007199254740991) throw new ArgumentException("会话来源无效。");
        return TrackAsync(token => Api.OpenChatAsync(copy, token), ct);
    }
    public Task<GetQqLoginResponse> GetQqLoginAsync(GetQqLoginRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.GetQqLoginAsync(copy, token), ct);
    }
    public Task<RefreshQqLoginQrcodeResponse> RefreshQqLoginQrcodeAsync(RefreshQqLoginQrcodeRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.RefreshQqLoginQrcodeAsync(copy, token), ct);
    }
    public Task<MediaInfo> PrepareMediaForOpenAsync(long chat, long sequence, MediaInfo media, CancellationToken ct = default)
    {
        ValidatePositiveId(chat); ValidatePositiveId(sequence);
        var copy = media.Clone();
        return TrackAsync(async token =>
        {
            var coordinator = new MediaOpenCoordinator(chat, sequence, copy, Api.RequestMediaAsync);
            void Updated(SubscribeResponse update) { if (update.MediaReady is { } ready) coordinator.Notify(ready); }
            Ephemeral += Updated;
            try { return await coordinator.ResolveAsync(token).ConfigureAwait(false); }
            finally { Ephemeral -= Updated; }
        }, ct);
    }
    public Task<RequestMediaResponse> RequestMediaAsync(RequestMediaRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.RequestMediaAsync(copy, token), ct);
    }
    public Task<SignMediaUrlsResponse> SignMediaUrlsAsync(SignMediaUrlsRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.SignMediaUrlsAsync(copy, token), ct);
    }
    public Task<GetAvatarsResponse> GetAvatarsAsync(GetAvatarsRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.GetAvatarsAsync(copy, token), ct);
    }
    public Task<GetForwardResponse> GetForwardAsync(GetForwardRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.GetForwardAsync(copy, token), ct);
    }
    public Task<SetPinnedResponse> SetPinnedAsync(SetPinnedRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.SetPinnedAsync(copy, token), ct);
    }
    public Task<SetNotifyPolicyResponse> SetNotifyPolicyAsync(SetNotifyPolicyRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.SetNotifyPolicyAsync(copy, token), ct);
    }
    public Task<SetMentionAllNotifyResponse> SetMentionAllNotifyAsync(SetMentionAllNotifyRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.SetMentionAllNotifyAsync(copy, token), ct);
    }
    public Task<ListStickersResponse> ListStickersAsync(ListStickersRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.ListStickersAsync(copy, token), ct);
    }
    public Task<PrepareStickersResponse> PrepareStickersAsync(PrepareStickersRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.PrepareStickersAsync(copy, token), ct);
    }
    public Task<AddStickerResponse> AddStickerAsync(AddStickerRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.AddStickerAsync(copy, token), ct);
    }
    public Task<ListSharedMediaResponse> ListSharedMediaAsync(ListSharedMediaRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.ListSharedMediaAsync(copy, token), ct);
    }
    public Task<ListUnreadMentionsResponse> ListUnreadMentionsAsync(ListUnreadMentionsRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.ListUnreadMentionsAsync(copy, token), ct);
    }
    public Task<MarkMentionsSeenResponse> MarkMentionsSeenAsync(MarkMentionsSeenRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.MarkMentionsSeenAsync(copy, token), ct);
    }
    public Task<ListReactionUsersResponse> ListReactionUsersAsync(ListReactionUsersRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.ListReactionUsersAsync(copy, token), ct);
    }
    public Task<ListGroupFilesResponse> ListGroupFilesAsync(ListGroupFilesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.ListGroupFilesAsync(copy, token), ct);
    }
    public Task<DeleteGroupFolderResponse> DeleteGroupFolderAsync(DeleteGroupFolderRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.DeleteGroupFolderAsync(copy, token), ct);
    }
    public Task<DeleteGroupFilesResponse> DeleteGroupFilesAsync(DeleteGroupFilesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.DeleteGroupFilesAsync(copy, token), ct);
    }
    public Task<RenameGroupFileResponse> RenameGroupFileAsync(RenameGroupFileRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.RenameGroupFileAsync(copy, token), ct);
    }
    public Task<MoveGroupFilesResponse> MoveGroupFilesAsync(MoveGroupFilesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.MoveGroupFilesAsync(copy, token), ct);
    }
    public Task<CreateGroupFolderResponse> CreateGroupFolderAsync(CreateGroupFolderRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.CreateGroupFolderAsync(copy, token), ct);
    }
    public Task<FetchGroupFileResponse> FetchGroupFileAsync(FetchGroupFileRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.FetchGroupFileAsync(copy, token), ct);
    }
    public Task<ListGroupNoticesResponse> ListGroupNoticesAsync(ListGroupNoticesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.ListGroupNoticesAsync(copy, token), ct);
    }
    public Task<ListGroupEssenceResponse> ListGroupEssenceAsync(ListGroupEssenceRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.ListGroupEssenceAsync(copy, token), ct);
    }
    public Task<ListGroupAlbumsResponse> ListGroupAlbumsAsync(ListGroupAlbumsRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.ListGroupAlbumsAsync(copy, token), ct);
    }
    public Task<ListGroupAlbumMediaResponse> ListGroupAlbumMediaAsync(ListGroupAlbumMediaRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.ListGroupAlbumMediaAsync(copy, token), ct);
    }
    public Task<ListGroupMembersResponse> ListGroupMembersAsync(ListGroupMembersRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.GroupId);
        return TrackAsync(token => Api.ListGroupMembersAsync(copy, token), ct);
    }
    public Task<GetChatStorageResponse> GetChatStorageAsync(GetChatStorageRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.GetChatStorageAsync(copy, token), ct);
    }
    public Task<ListStoragePoliciesResponse> ListStoragePoliciesAsync(ListStoragePoliciesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.ListStoragePoliciesAsync(copy, token), ct);
    }
    public Task<SetStoragePolicyResponse> SetStoragePolicyAsync(SetStoragePolicyRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.SetStoragePolicyAsync(copy, token), ct);
    }
    public Task<DeleteStoragePolicyResponse> DeleteStoragePolicyAsync(DeleteStoragePolicyRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.DeleteStoragePolicyAsync(copy, token), ct);
    }
    public Task<PlanCleanupResponse> PlanCleanupAsync(PlanCleanupRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.PlanCleanupAsync(copy, token), ct);
    }
    public Task<ExecuteCleanupResponse> ExecuteCleanupAsync(ExecuteCleanupRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.ExecuteCleanupAsync(copy, token), ct);
    }
    public Task<GetStorageOverviewResponse> GetStorageOverviewAsync(GetStorageOverviewRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.GetStorageOverviewAsync(copy, token), ct);
    }
    public Task<ListStorageChatsResponse> ListStorageChatsAsync(ListStorageChatsRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.ListStorageChatsAsync(copy, token), ct);
    }
    public Task<ListStorageItemsResponse> ListStorageItemsAsync(ListStorageItemsRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.ListStorageItemsAsync(copy, token), ct);
    }
    public Task<ListMediaUsagesResponse> ListMediaUsagesAsync(ListMediaUsagesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.ListMediaUsagesAsync(copy, token), ct);
    }
    public Task<GetStatusResponse> GetStatusAsync(GetStatusRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.GetStatusAsync(copy, token), ct);
    }
    public Task<ListArchiveStatusResponse> ListArchiveStatusAsync(ListArchiveStatusRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); return TrackAsync(token => Api.ListArchiveStatusAsync(copy, token), ct);
    }
    public Task<SetDeepArchiveResponse> SetDeepArchiveAsync(SetDeepArchiveRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.SetDeepArchiveAsync(copy, token), ct);
    }
    public Task<FillHolesNowResponse> FillHolesNowAsync(FillHolesNowRequest request, CancellationToken ct = default) =>
        TrackAsync(token => Api.FillHolesNowAsync(new(), token), ct);
    public Task<ListDevicesResponse> ListDevicesAsync(ListDevicesRequest request, CancellationToken ct = default) =>
        TrackAsync(token => Api.ListDevicesAsync(new(), token), ct);
    public Task<RevokeDeviceResponse> RevokeDeviceAsync(RevokeDeviceRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.DeviceId);
        return TrackAsync(token => Api.RevokeDeviceAsync(copy, token), ct);
    }
    public Task<MarkReadResponse> MarkReadAsync(MarkReadRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        if (copy.MaxSeq is < 0 or > 9007199254740991) throw new ArgumentException("已读序号无效。");
        return TrackAsync(token => Api.MarkReadAsync(copy, token), ct);
    }
    public Task<SetTypingResponse> SetTypingAsync(long chat, CancellationToken ct = default)
    {
        ValidatePositiveId(chat);
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            ct.ThrowIfCancellationRequested();
            long now = Environment.TickCount64;
            if (typingChats.Contains(chat) || (typingTimes.TryGetValue(chat, out long previous) && now - previous < 4000))
                return Task.FromResult(new SetTypingResponse { Sent = false });
            typingChats.Add(chat); typingTimes[chat] = now;
            return TrackAsync(async token =>
            {
                try { return await Api.SetTypingAsync(new() { ChatId = chat }, token).ConfigureAwait(false); }
                finally { lock (gate) typingChats.Remove(chat); }
            }, ct);
        }
    }
    public Task<TranscribeVoiceResponse> TranscribeVoiceAsync(TranscribeVoiceRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        ValidatePositiveId(copy.ChatId); ValidatePositiveId(copy.Seq);
        return TrackAsync(token => Api.TranscribeVoiceAsync(copy, token), ct);
    }
    public Task<ListAiVoicesResponse> ListAiVoicesAsync(ListAiVoicesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        return TrackAsync(token => Api.ListAiVoicesAsync(copy, token), ct);
    }
    public Task<SendAiVoiceResponse> SendAiVoiceAsync(SendAiVoiceRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone(); ValidatePositiveId(copy.ChatId);
        if (string.IsNullOrWhiteSpace(copy.VoiceId) || string.IsNullOrWhiteSpace(copy.Text))
            throw new ArgumentException("语音角色和朗读内容不能为空。");
        copy.Text = copy.Text.Trim();
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            if (!sendingVoiceChats.Add(copy.ChatId)) throw new InvalidOperationException("此群的 AI 语音尚未确认，请等待结果。");
            return TrackAsync(async token =>
            {
                try { return await Api.SendAiVoiceAsync(copy, token).ConfigureAwait(false); }
                finally { lock (gate) sendingVoiceChats.Remove(copy.ChatId); }
            }, ct);
        }
    }
    private static void ValidatePositiveId(long value)
    {
        if (value is <= 0 or > 9007199254740991) throw new ArgumentException("会话或消息标识无效。");
    }
    public Task<SearchMessagesResponse> SearchMessagesAsync(SearchMessagesRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return TrackAsync(token => Api.SearchMessagesAsync(copy, token), ct);
    }
    public Task<RecallMessageResponse> RecallMessageAsync(RecallMessageRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return ChangeMessageAsync(copy.ChatId, copy.Seq, token => Api.RecallMessageAsync(copy, token), ct);
    }
    public Task<ReactResponse> ReactAsync(ReactRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        if (copy.EmojiId.Length is < 1 or > 10 || !copy.EmojiId.All(c => c is >= '0' and <= '9'))
            throw new ArgumentException("回应表情 ID 必须是 1 至 10 位数字。");
        return ChangeMessageAsync(copy.ChatId, copy.Seq, async token =>
        {
            var response = await Api.ReactAsync(copy, token).ConfigureAwait(false);
            if (response.Message is not { } message || message.ChatId != copy.ChatId || message.Seq != copy.Seq)
                throw new IOException("回应确认与请求的消息不匹配，请等待同步确认。");
            var page = new GetHistoryResponse(); page.Messages.Add(message);
            // RPC 是单条快照，不证明 chat_pts 连续；合并版本但不修改历史窗口或同步游标。
            await Repository.MergeHistoryPageAsync(copy.ChatId, page, false, CancellationToken.None).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            return response;
        }, ct);
    }
    private Task<T> ChangeMessageAsync<T>(long chat, long seq, Func<CancellationToken, Task<T>> action, CancellationToken ct)
    {
        if (chat is <= 0 or > 9007199254740991 || seq is <= 0 or > 9007199254740991)
            throw new ArgumentException("消息所属会话或序号无效。");
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            if (!changingMessages.Add((chat, seq))) throw new InvalidOperationException("此消息的操作尚未完成，请等待结果。");
            return TrackAsync(async token =>
            {
                try { return await action(token).ConfigureAwait(false); }
                finally { lock (gate) changingMessages.Remove((chat, seq)); }
            }, ct);
        }
    }
    public Task SetActiveChatAsync(long chat, CancellationToken ct = default)
    {
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            // 在调用线程登记意图，不能先 Task.Run，否则快速切换的两个请求可能倒序进入协调器。
            async Task Run()
            {
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
                await activeChat.SetAsync(chat, linked.Token).ConfigureAwait(false);
            }
            var task = Run();
            sessionTasks.Add(task);
            _ = task.ContinueWith(finished => { lock (gate) sessionTasks.Remove(finished); },
                CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return task;
        }
    }
    private static SendMessageRequest ValidateMessage(SendMessageRequest request)
    {
        var copy = request.Clone();
        OutgoingValidation.Validate(copy);
        return copy;
    }
    private Task<T> TrackAsync<T>(Func<CancellationToken, Task<T>> action, CancellationToken ct)
    {
        lock (gate)
        {
            if (closing is not null) throw new ObjectDisposedException(nameof(ClientSessionRuntime));
            var task = Task.Run(async () =>
            {
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
                return await action(linked.Token).ConfigureAwait(false);
            });
            sessionTasks.Add(task);
            _ = task.ContinueWith(finished => { lock (gate) sessionTasks.Remove(finished); },
                CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            return task;
        }
    }
    private Task RunAsync()
    {
        // 活动通话不在持久化差量中。恢复请求与同步并行，避免通话接口慢时阻塞消息；
        // ViewModel 的事件修订号阻止迟到快照覆盖 Subscribe 已收到的新状态。
        QueueDialogs();
        return Task.WhenAll(sync.RunAsync(lifetime.Token), Calls.RestoreAsync(lifetime.Token), ObserveDialogsAsync());
    }
    private void QueueDialogs() => dialogChanges.Writer.TryWrite(true);
    private async Task ObserveDialogsAsync()
    {
        try
        {
            while (await dialogChanges.Reader.WaitToReadAsync(lifetime.Token).ConfigureAwait(false))
            {
                // 容量为 1 的失效信号合并突发提交；加载过程中到达的变更留待下一轮。
                while (dialogChanges.Reader.TryRead(out _)) { }
                await Dialogs.Load.WaitForIdleAsync().ConfigureAwait(false);
                lifetime.Token.ThrowIfCancellationRequested();
                await Dialogs.LoadAsync(lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }
    private async Task ReceiveAsync(SubscribeResponse update, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (update.Call is { Call: { } call }) await Calls.ApplyUpdateAsync(call).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        Ephemeral?.Invoke(update);
    }
    private void StatusChanged(string status) => ConnectionStatus?.Invoke(status);
    private void InvalidateChat(long chat) => ChatInvalidated?.Invoke(chat);
    private void ReceiveMessage(Message message) => StreamMessageReceived?.Invoke(message);
    public ValueTask DisposeAsync()
    {
        lock (gate)
        {
            // 关闭在后台进入，避免取消回调或测试替身同步完成时重入组合根锁。
            closing ??= Task.Run(CloseAsync);
            return new ValueTask(closing);
        }
    }
    private async Task CloseAsync()
    {
        store.DialogsChanged -= QueueDialogs;
        store.PeersChanged -= QueueDialogs;
        dialogChanges.Writer.TryComplete();
        lifetime.Cancel(); Contacts.Dispose(); Calls.Dispose(); Dialogs.Dispose();
        try
        {
            Task[] loads;
            lock (gate) loads = sessionTasks.ToArray();
            await Task.WhenAll(loads.Concat(new[] { running ?? Task.CompletedTask,
                Contacts.DisposeAsync().AsTask(), Calls.DisposeAsync().AsTask(), Dialogs.DisposeAsync().AsTask() })).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        finally
        {
            sync.EphemeralReceived -= ReceiveAsync; sync.Status -= StatusChanged;
            sync.ChatInvalidated -= InvalidateChat;
            sync.StreamMessageReceived -= ReceiveMessage;
            try { await Repository.DisposeAsync().ConfigureAwait(false); }
            finally { store.Dispose(); transport.Dispose(); lifetime.Dispose(); }
        }
    }
}
