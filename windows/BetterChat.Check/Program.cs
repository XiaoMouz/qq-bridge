using BetterChat;
using BetterChat.Core;
using BetterChat.Infrastructure;
using BetterChat.Application.ViewModels;
using Qqbridge.V1;
using System.Diagnostics;

// 仅使用已保存的本机凭据；不输出地址、令牌、联系人、消息或服务器错误正文。
if (args.SequenceEqual(new[] { "--test-session-format" }))
{
    // 无效密文能被序列化而不触发解密，证明 Token getter 不参与 JSON 保存。
    string serialized = System.Text.Json.JsonSerializer.Serialize(new SessionSettings("https://fixture.invalid", "not-base64"));
    using var json = System.Text.Json.JsonDocument.Parse(serialized);
    bool valid = json.RootElement.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(new[] { "ProtectedToken", "Server" });
    Console.WriteLine(valid ? "通过：登录文件只序列化服务器与受保护凭据。" : "失败：登录文件字段不符合预期。");
    return valid ? 0 : 1;
}
if (args.SequenceEqual(new[] { "--repair-session" }))
{
    try
    {
        bool repaired = SessionSettings.RemoveLegacyPlaintext();
        Console.WriteLine(repaired ? "已移除旧登录文件的明文令牌副本，保留受保护凭据。" : "没有需要移除的旧明文副本。");
        return SessionSettings.LoadError is null ? 0 : 2;
    }
    catch (Exception error) { Console.WriteLine("凭据文件修复失败：" + error.GetType().Name); return 1; }
}
if (!args.SequenceEqual(new[] { "--read-only" }))
{
    Console.WriteLine("用法：dotnet run --project windows/BetterChat.Check -- --read-only");
    return 2;
}
SessionSettings? saved;
string token;
try
{
    saved = SessionSettings.Load();
    if (saved is null) { Console.WriteLine(SessionSettings.LoadError ?? "没有已保存会话，请在客户端自行登录后再验收。"); return 2; }
    token = saved.Token;
}
catch (Exception error) { Console.WriteLine("本机凭据不可用：" + error.GetType().Name); return 2; }
using var transport = new ConnectClient(Authentication.ServerUri(saved.Server)) { Token = token };
var api = new BridgeApi(transport);
using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
int passed = 0, failed = 0;
async Task<T?> Check<T>(string name, Func<Task<T>> run, Func<T, bool>? valid = null) where T : class
{
    var watch = Stopwatch.StartNew();
    try
    {
        var value = await run();
        if (valid is not null && !valid(value)) throw new InvalidDataException();
        passed++; Console.WriteLine($"通过 {name} ({watch.ElapsedMilliseconds} ms)"); return value;
    }
    catch (Exception error)
    {
        failed++; Console.WriteLine($"失败 {name}: {(error is RpcException rpc ? rpc.Code : error.GetType().Name)} ({watch.ElapsedMilliseconds} ms)"); return null;
    }
}
var ct = timeout.Token;
var state = await Check("GetState", () => api.GetStateAsync(new(), ct), r => r.Pts >= 0);
if (state is null) return 1;
await Check("GetDifference/当前游标", () => api.GetDifferenceAsync(new() { Pts = state.Pts, Limit = 50 }, ct), r => r.Difference is not null && !r.Difference.TooLong);
await Check("GetDifference/新客户端零游标", () => api.GetDifferenceAsync(new() { Pts = 0, Limit = 20 }, ct), r => r.Difference is not null && !r.Difference.TooLong);
var dialogs = await Check("ListDialogs", () => api.ListDialogsAsync(new() { Limit = 30 }, ct), r => r.Dialogs.All(d => d.ChatId > 0));
var friends = await Check("ListFriends", () => api.ListFriendsAsync(new(), ct));
var groups = await Check("ListGroups", () => api.ListGroupsAsync(new(), ct));
await Check("ListDevices", () => api.ListDevicesAsync(new(), ct));
await Check("GetStatus", () => api.GetStatusAsync(new(), ct));
await Check("ListArchiveStatus", () => api.ListArchiveStatusAsync(new() { Limit = 20 }, ct), r => r.Chats.All(c => c.ChatId > 0));
var globalSearch = await Check("SearchMessages/全局首屏", () => api.SearchMessagesAsync(new() { Query = "测试", Limit = 1 }, ct),
    r => r.Messages.Count <= 1 && r.Messages.All(m => m.ChatId > 0 && m.Seq > 0));
if (globalSearch?.Next is { } globalCursor)
    await Check("SearchMessages/全局下一页", () => api.SearchMessagesAsync(new() { Query = "测试", Limit = 1, Before = globalCursor.Clone() }, ct),
        r => r.Messages.Count <= 1 && !r.Messages.Any(m => globalSearch.Messages.Any(first => first.ChatId == m.ChatId && first.Seq == m.Seq)));
else Console.WriteLine("跳过全局搜索下一页：没有下一页游标。");
if (globalSearch?.Messages.FirstOrDefault() is { } hit)
    await Check("搜索结果定位/GetHistoryAround", () => api.GetHistoryAsync(new() { ChatId = hit.ChatId, AnchorSeq = hit.Seq, Direction = HistoryDirection.Around, Limit = 10 }, ct),
        r => r.Messages.All(m => m.ChatId == hit.ChatId) && r.Messages.Any(m => m.Seq == hit.Seq));
else Console.WriteLine("跳过搜索结果定位：当前查询没有匹配消息。");
var storage = await Check("GetStorageOverview", () => api.GetStorageOverviewAsync(new() { Limit = 5 }, ct));
if (storage?.Categories.FirstOrDefault(c => c.Bytes > 0 && StorageCategories.HasMediaItems(c.Category)) is { } category)
{
    var query = new ListStorageChatsRequest { Limit = 20 }; query.Categories.Add(category.Category);
    var chats = await Check("ListStorageChats/分类", () => api.ListStorageChatsAsync(query, ct), r => r.Chats.All(c => c.ChatId > 0));
    if (chats?.Chats.FirstOrDefault() is { } storageChat)
    {
        var itemQuery = new ListStorageItemsRequest { ChatId = storageChat.ChatId, Limit = 1 }; itemQuery.Categories.Add(category.Category);
        var items = await Check("ListStorageItems/首屏", () => api.ListStorageItemsAsync(itemQuery, ct), r => r.Items.Count <= 1);
        if (items is { More: true } && items.Items.Count > 0)
        {
            var next = itemQuery.Clone(); next.Offset = (uint)items.Items.Count;
            await Check("ListStorageItems/下一页", () => api.ListStorageItemsAsync(next, ct), r => r.Items.Count <= 1);
        }
        else Console.WriteLine("跳过存储下一页：没有更多内容。");
        if (items?.Items.FirstOrDefault() is { } media)
            await Check("ListMediaUsages/存储引用", () => api.ListMediaUsagesAsync(new() { Sha256 = media.Sha256 }, ct), r => r.Usages.All(u => u.ChatId > 0));
        else Console.WriteLine("跳过存储引用：分类没有媒体内容。");
    }
    else Console.WriteLine("跳过存储内容：分类没有会话。");
}
else Console.WriteLine("跳过存储分类浏览：概览没有媒体分类。");
await Check("ListStoragePolicies", () => api.ListStoragePoliciesAsync(new(), ct));
await Check("ListStickers/缓存列表", () => api.ListStickersAsync(new() { Refresh = false }, ct));
if (friends?.Friends.FirstOrDefault() is { } friend)
    await Check("GetUserProfile/缓存优先", () => api.GetUserProfileAsync(new() { UserId = friend.PeerId }, ct), r => r.Profile?.Peer?.PeerId == friend.PeerId);
var group = groups?.Groups.FirstOrDefault(g => g.PeerId == 521409608) ?? groups?.Groups.FirstOrDefault();
if (group is not null)
{
    long id = group.PeerId;
    await Check("GetGroupProfile/缓存优先", () => api.GetGroupProfileAsync(new() { GroupId = id }, ct), r => r.Profile?.Peer?.PeerId == id);
    await Check("ListGroupMembers", () => api.ListGroupMembersAsync(new() { GroupId = id, Limit = 20 }, ct));
    var pagingGroup = groups!.Groups.FirstOrDefault(g => g.MemberCount > 100) ?? group;
    using (var members = new GroupMembersViewModel(pagingGroup.PeerId, api.ListGroupMembersAsync, new CheckDispatcher()))
    {
        var first = await Check("群成员 ViewModel/首屏", async () =>
        {
            if (!await members.LoadMoreAsync(ct)) throw new InvalidOperationException();
            return members.Members.Select(m => m.UserId).ToArray();
        }, ids => ids.All(id => id > 0) && ids.Distinct().Count() == ids.Length);
        if (first is not null && members.HasMore)
            await Check("群成员 ViewModel/下一页追加与去重", async () =>
            {
                if (!await members.LoadMoreAsync(ct)) throw new InvalidOperationException();
                return members.Members.Select(m => m.UserId).ToArray();
            }, ids => ids.Take(first.Length).SequenceEqual(first) && ids.Distinct().Count() == ids.Length
                && (ids.Length > first.Length || !members.HasMore));
        else Console.WriteLine("跳过群成员 ViewModel 下一页：首屏失败或没有更多成员。");
    }
    await Check("ListGroupNotices", () => api.ListGroupNoticesAsync(new() { GroupId = id }, ct));
    await Check("ListGroupEssence", () => api.ListGroupEssenceAsync(new() { GroupId = id }, ct));
    await Check("ListGroupFiles/根目录", () => api.ListGroupFilesAsync(new() { GroupId = id }, ct));
    var albums = await Check("ListGroupAlbums", () => api.ListGroupAlbumsAsync(new() { GroupId = id }, ct));
    if (albums?.Albums.FirstOrDefault() is { } album)
        await Check("ListGroupAlbumMedia/首屏", () => api.ListGroupAlbumMediaAsync(new() { GroupId = id, AlbumId = album.Id }, ct));
    else Console.WriteLine("跳过相册媒体：所选群没有可用相册。");
}
if (dialogs?.Dialogs.FirstOrDefault() is { } selected)
{
    long chat = selected.ChatId;
    var history = await Check("GetHistory", () => api.GetHistoryAsync(new() { ChatId = chat, Limit = 20, Direction = HistoryDirection.Older }, ct),
        r => r.Messages.All(m => m.ChatId == chat) && r.Events.All(e => e.ChatId == chat));
    await Check("GetChatDifference/当前游标", () => api.GetChatDifferenceAsync(new() { ChatId = chat, ChatPts = selected.ChatPts, Limit = 20 }, ct));
    await Check("ListSharedMedia", () => api.ListSharedMediaAsync(new() { ChatId = chat, Limit = 10, Sort = "time_desc" }, ct));
    await Check("ListUnreadMentions", () => api.ListUnreadMentionsAsync(new() { ChatId = chat }, ct));
    await Check("GetChatStorage", () => api.GetChatStorageAsync(new() { ChatId = chat, TopLimit = 5 }, ct), r => r.Summary?.ChatId == chat);
    var search = await Check("SearchMessages/会话过滤", () => api.SearchMessagesAsync(new() { ChatId = chat, Query = "测试", Limit = 10 }, ct),
        r => r.Messages.Count <= 10 && r.Messages.All(m => m.ChatId == chat && m.Seq > 0));
    if (search?.Next is { } cursor)
        await Check("SearchMessages/下一页", () => api.SearchMessagesAsync(new() { ChatId = chat, Query = "测试", Limit = 10, Before = cursor.Clone() }, ct),
            r => r.Messages.All(m => m.ChatId == chat && !search.Messages.Any(first => first.Seq == m.Seq)));
    else Console.WriteLine("跳过搜索下一页：当前查询没有下一页游标。");
    string? preview = history?.Messages.SelectMany(m => m.Segments)
        .Select(s => s.Image?.Media ?? s.Video?.Media ?? s.MarketFace?.Media)
        .Where(m => m is not null).Select(m => MediaPresentation.PreviewHash(m!)).FirstOrDefault(s => s.Length == 64);
    if (preview is not null)
    {
        string directory = Path.Combine(Path.GetTempPath(), "betterchat-read-check-" + Guid.NewGuid().ToString("N"));
        try
        {
            await Check("真实预览下载/哈希/离线缓存", async () =>
            {
                var cache = new PreviewCache(directory);
                string path = await cache.GetAsync(preview, async (output, cancel) =>
                {
                    var request = new SignMediaUrlsRequest(); request.Sha256.Add(preview);
                    var signed = await api.SignMediaUrlsAsync(request, cancel);
                    var url = signed.Urls.Single(u => u.Sha256 == preview).Url;
                    await transport.DownloadPreviewAsync(url, output, cancel);
                }, ct);
                string offline = await cache.GetAsync(preview, (_, _) => throw new IOException("缓存未命中"), ct);
                if (path != offline) throw new InvalidDataException();
                return new object();
            });
        }
        finally
        {
            if (Directory.Exists(directory))
            { foreach (string file in Directory.GetFiles(directory)) File.Delete(file); Directory.Delete(directory); }
        }
    }
    else Console.WriteLine("跳过真实预览：所取历史页没有可用预览哈希。");
}
await Check("真实冷启动/差量分页/首屏预取/列表投影", async () =>
{
    using var store = new LocalStore(":memory:");
    using var stopped = CancellationTokenSource.CreateLinkedTokenSource(ct);
    stopped.CancelAfter(TimeSpan.FromSeconds(60));
    bool initialized = false, prefetchFailed = false;
    var sync = new SyncEngine(api, store);
    sync.Status += status =>
    {
        // 完成追平与首屏预取后停止，不创建第二条在线 Subscribe。
        if (status == "已连接") { initialized = true; stopped.Cancel(); }
        if (status.StartsWith("首屏预取失败", StringComparison.Ordinal)) prefetchFailed = true;
    };
    await sync.RunAsync(stopped.Token);
    if (!initialized || prefetchFailed || store.Cursor() < state.Pts) throw new InvalidDataException();
    var targets = store.Dialogs.OrderByDescending(d => d.Pinned).ThenByDescending(d => d.UnreadCount > 0)
        .ThenByDescending(d => d.TopTime).Take(30).Where(d => d.ChatPts > 0).ToArray();
    if (targets.Any(d => store.Cursor("chat:" + d.ChatId) < d.ChatPts || store.LatestHistory(d.ChatId) is null))
        throw new InvalidDataException();
    await using var repository = new LocalRepository(store);
    await using var viewModel = new DialogListViewModel(repository, new CheckDispatcher());
    if (!await viewModel.Load.ExecuteAsync(new(), ct) || viewModel.Items.Count != store.Dialogs.Count)
        throw new InvalidDataException();
    return new object();
});
Console.WriteLine($"只读验收：{passed} 通过，{failed} 失败。未发送消息、未标记已读、未修改设置。");
return failed == 0 ? 0 : 1;

sealed class CheckDispatcher : IUiDispatcher
{
    public Task InvokeAsync(Action action) { action(); return Task.CompletedTask; }
}
