using BetterChat.Application;
using BetterChat.Infrastructure;
using System.Reflection;
using BetterChat.Application.ViewModels;
using Microsoft.Data.Sqlite;
using System.Buffers.Binary;
using System.Net;
using Google.Protobuf;
using BetterChat.Core;
using Qqbridge.V1;

int passed = 0;
async Task Test(string name, Func<Task> test) { await test(); Console.WriteLine("通过：" + name); passed++; }
void Check(bool value) { if (!value) throw new Exception("断言失败"); }
byte[] Frame(byte flags, byte[] payload)
{
    var data = new byte[payload.Length + 5]; data[0] = flags;
    BinaryPrimitives.WriteUInt32BigEndian(data.AsSpan(1), (uint)payload.Length); payload.CopyTo(data, 5); return data;
}
await Test("64 位 ID 与 oneof 往返", () =>
{
    var req = new SendMessageRequest { ChatId = long.MaxValue }; req.Segments.Add(new OutgoingSegment { Text = "中文 👋" });
    var result = SendMessageRequest.Parser.ParseFrom(req.ToByteArray());
    Check(result.ChatId == long.MaxValue && result.Segments[0].Text == "中文 👋"); return Task.CompletedTask;
});
await Test("Unary 认证、路径和 protobuf", async () =>
{
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        Check(request.RequestUri!.AbsolutePath == "/qqbridge.v1.SyncService/GetState");
        Check(request.Headers.Authorization?.Parameter == "fixture-only");
        Check(request.Headers.GetValues("Connect-Protocol-Version").Single() == "1");
        Check(request.Content!.Headers.ContentType!.MediaType == "application/proto");
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new GetStateResponse { Pts = 42 }.ToByteArray()) });
    })) { Token = "fixture-only" };
    Check((await new BridgeApi(client).GetStateAsync(new())).Pts == 42);
});
await Test("流分片读取和结束帧", async () =>
{
    var body = Frame(0, new SubscribeResponse { Heartbeat = new Heartbeat { Pts = 99 } }.ToByteArray()).Concat(Frame(2, "{}"u8.ToArray())).ToArray();
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var input = await request.Content!.ReadAsByteArrayAsync(); Check(input[0] == 0 && SubscribeRequest.Parser.ParseFrom(input[5..]).Pts == 12);
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new FragmentedStream(body)) };
    }));
    var updates = new List<SubscribeResponse>(); await foreach (var item in new BridgeApi(client).SubscribeAsync(new() { Pts = 12 })) updates.Add(item);
    Check(updates.Count == 1 && updates[0].Heartbeat.Pts == 99);
});
await Test("结束帧鉴权错误", async () =>
{
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
    { Content = new ByteArrayContent(Frame(2, "{\"error\":{\"code\":\"unauthenticated\",\"message\":\"expired\"}}"u8.ToArray())) })));
    bool caught = false; try { await foreach (var _ in new BridgeApi(client).SubscribeAsync(new())) { } } catch (RpcException e) { caught = e.Code == "unauthenticated"; } Check(caught);
});
await Test("拒绝超大帧和截断帧", async () =>
{
    foreach (var bytes in new[] { new byte[] { 0, 127, 255, 255, 255 }, new byte[] { 0, 0, 0, 0, 5, 1 } })
    {
        using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) })));
        bool caught = false; try { await foreach (var _ in new BridgeApi(client).SubscribeAsync(new())) { } } catch (IOException) { caught = true; } Check(caught);
    }
});
await Test("缓存持久化、去重、历史游标和墓碑", () =>
{
    string path = Path.Combine(Path.GetTempPath(), "betterchat-test-" + Guid.NewGuid() + ".db");
    try
    {
        using (var store = new LocalStore(path))
        {
            var d = new Difference { Pts = 10 }; d.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 10 }); store.Apply(d);
            store.ApplyChat(153, 2, [new Message { ChatId = 153, Seq = 3, Version = 2, Text = "新" }], []);
            store.MergeHistory(153, [new Message { ChatId = 153, Seq = 3, Version = 1, Text = "旧" }], []);
            Check(store.Messages(153).Single().Text == "新" && store.Cursor("chat:153") == 2);
            store.SavePending(new SendMessageRequest { ChatId = 153, ClientRandomId = 7 });
            store.AcceptPending(new OutboxEntry { ChatId = 153, ClientRandomId = 7, Pts = 15, State = OutboxState.Pending });
            Check(store.Cursor() == 10 && store.Read("pending", SendMessageRequest.Parser).Count == 0);
        }
        using (var store = new LocalStore(path))
        {
            Check(store.Cursor() == 10 && store.Messages(153).Count == 1);
            var d = new Difference { Pts = 11 }; d.Tombstones.Add(new Tombstone { Entity = "chat", Key = "153" }); store.Apply(d);
            Check(store.Dialogs.Count == 0 && store.Messages(153).Count == 0 && store.Cursor("chat:153") == 0);
        }
    }
    finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
    return Task.CompletedTask;
});
await Test("重置保留待发送幂等 ID", () =>
{
    using var store = new LocalStore(":memory:"); store.SavePending(new SendMessageRequest { ChatId = 153, ClientRandomId = 55 }); store.Reset();
    Check(store.Read("pending", SendMessageRequest.Parser).Single().ClientRandomId == 55); return Task.CompletedTask;
});
await Test("同步缺口通过差量补齐", async () =>
{
    using var store = new LocalStore(":memory:"); store.Apply(new Difference { Pts = 1, IsFinal = true });
    using var done = new CancellationTokenSource(TimeSpan.FromSeconds(5)); int diffs = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        byte[] response = request.RequestUri!.Segments.Last() switch
        {
            "GetState" => new GetStateResponse { Pts = 3 }.ToByteArray(), "GetDifference" => Difference(),
            "Subscribe" => Frame(0, new SubscribeResponse { Dialog = new DialogUpdate { Pts = 3, Dialog = new Dialog { ChatId = 153, DialogPts = 3 } } }.ToByteArray()).Concat(Frame(2, "{}"u8.ToArray())).ToArray(),
            _ => throw new Exception("意外请求")
        };
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) });
        byte[] Difference()
        {
            diffs++; var d = new Difference { Pts = diffs == 1 ? 1 : 3, IsFinal = true };
            if (diffs > 1) d.Peers.Add(new Peer { PeerId = 123, Name = "补齐的联系人", Pts = 2 });
            return new GetDifferenceResponse { Difference = d }.ToByteArray();
        }
    }));
    store.Changed += () => { if (store.Cursor() == 3) done.Cancel(); };
    await new SyncEngine(new BridgeApi(client), store).RunAsync(done.Token);
    Check(diffs == 2 && store.Peers.Single().Name == "补齐的联系人");
});
await Test("全局异常分页进入退避且不应用坏页，重复全量过期不空转", async () =>
{
    foreach (var mode in new[] { "same", "backward", "missing", "expired" })
    {
        using var store = new LocalStore(":memory:");
        var seed = new Difference { Pts = 5, IsFinal = true };
        seed.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 5 }); store.Apply(seed);
        store.SavePending(new SendMessageRequest { ChatId = 153, ClientRandomId = 55 });
        using var done = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        int requests = 0; bool backedOff = false;
        using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
        {
            byte[] response;
            if (request.RequestUri!.Segments.Last() == "GetState") response = new GetStateResponse { Pts = 5 }.ToByteArray();
            else if (request.RequestUri.Segments.Last() == "GetDifference")
            {
                requests++;
                if (requests > 3) { done.Cancel(); throw new Exception("分页空转"); }
                var d = new Difference { Pts = mode == "backward" ? 4 : 5, IsFinal = mode == "backward", TooLong = mode == "expired" };
                d.Tombstones.Add(new Tombstone { Entity = "chat", Key = "153" });
                response = (mode == "missing" ? new GetDifferenceResponse() : new GetDifferenceResponse { Difference = d }).ToByteArray();
            }
            else throw new Exception("坏页后不能进入订阅");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) });
        }));
        var sync = new SyncEngine(new BridgeApi(client), store);
        sync.Status += status => { if (status.Contains("秒后重试")) { backedOff = true; done.Cancel(); } };
        await sync.RunAsync(done.Token);
        Check(backedOff && requests == (mode == "expired" ? 2 : 1));
        Check(store.Cursor() == (mode == "expired" ? 0 : 5));
        Check(store.Dialogs.Count == (mode == "expired" ? 0 : 1));
        Check(store.Read("pending", SendMessageRequest.Parser).Single().ClientRandomId == 55);
    }
});
await Test("全局迟到过期响应不能清除已推进的本地快照", async () =>
{
    using var store = new LocalStore(":memory:"); store.Apply(new Difference { Pts = 5, IsFinal = true });
    using var done = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var requested = new List<long>(); bool subscribed = false;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        byte[] response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "GetState": response = new GetStateResponse { Pts = 6 }.ToByteArray(); break;
            case "GetDifference":
                requested.Add(GetDifferenceRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()).Pts);
                if (requested.Count == 1)
                {
                    var newer = new Difference { Pts = 6, IsFinal = true };
                    newer.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 6 }); store.Apply(newer);
                }
                response = new GetDifferenceResponse { Difference = new Difference { Pts = 6, IsFinal = true, TooLong = requested.Count == 1 } }.ToByteArray(); break;
            case "Subscribe": subscribed = true; done.Cancel(); response = Frame(2, "{}"u8.ToArray()); break;
            default: throw new Exception("意外请求");
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) };
    }));
    await new SyncEngine(new BridgeApi(client), store).RunAsync(done.Token);
    Check(subscribed && requested.SequenceEqual(new long[] { 5, 6 }) && store.Cursor() == 6 && store.Dialogs.Single().ChatId == 153);
});
await Test("首屏事务失败完整回滚，提交后重开恢复且旧预取不能覆盖新游标", () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        var page = new GetHistoryResponse { ChatPts = 5 };
        page.Messages.Add(new Message { ChatId = 153, Seq = 50, Version = 5 });
        using (var store = new LocalStore(path))
        {
            var old = new GetHistoryResponse(); old.Messages.Add(new Message { ChatId = 153, Seq = 1, Version = 1 });
            store.MergeHistory(153, old.Messages, []); store.SaveLatestHistory(153, old);
            store.SavePending(new SendMessageRequest { ChatId = 153, ClientRandomId = 55 });
            int changes = 0; store.Changed += () => changes++;
            using var db = new SqliteConnection($"Data Source={path};Pooling=False"); db.Open();
            using var command = db.CreateCommand();
            command.CommandText = "CREATE TRIGGER reject_history BEFORE INSERT ON records WHEN NEW.kind='history' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;";
            command.ExecuteNonQuery();
            try { store.TryApplyFirstScreen(153, page, true); throw new Exception("应回滚首屏事务"); } catch (SqliteException) { }
            Check(changes == 0 && store.Cursor("chat:153") == 0 && store.Messages(153).Single().Seq == 1 && store.LatestHistory(153)!.Messages.Single().Seq == 1);
            command.CommandText = "DROP TRIGGER reject_history"; command.ExecuteNonQuery();
            Check(store.TryApplyFirstScreen(153, page, true) && changes == 1);
            var bad = page.Clone(); bad.Messages[0].ChatId = 999;
            try { store.TryApplyFirstScreen(154, bad, true); throw new Exception("应拒绝其他会话数据"); } catch (ArgumentException) { }
            Check(store.Cursor("chat:154") == 0 && changes == 1);
        }
        using (var store = new LocalStore(path))
        {
            Check(store.Cursor("chat:153") == 5 && store.Messages(153).Single().Seq == 50 && store.LatestHistory(153)!.ChatPts == 5);
            store.ApplyChat(153, 6, [new Message { ChatId = 153, Seq = 60, Version = 6 }], []);
            int changes = 0; store.Changed += () => changes++;
            Check(!store.TryApplyFirstScreen(153, page, true));
            Check(changes == 0 && store.Cursor("chat:153") == 6 && store.Messages(153).Count == 2);
            Check(store.Read("pending", SendMessageRequest.Parser).Single().ClientRandomId == 55);
        }
    }
    finally { SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
    return Task.CompletedTask;
});
await Test("首屏预取限制优先范围并保存连续窗口，重复响应与搜索孤岛不混入", async () =>
{
    using var store = new LocalStore(":memory:");
    var seed = new Difference { Pts = 1, IsFinal = true };
    for (int id = 1; id <= 40; id++) seed.Dialogs.Add(new Dialog { ChatId = id, ChatPts = 5, TopTime = id, Pinned = id == 1, UnreadCount = id == 2 ? 1u : 0u });
    store.Apply(seed);
    store.MergeHistory(1, [new Message { ChatId = 1, Seq = 1, Version = 1 }], []);
    int calls = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        Check(request.RequestUri!.Segments.Last() == "GetChatDifferences"); calls++;
        var input = GetChatDifferencesRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(input.PerChatLimit == 30 && input.Chats.Count == 30 && input.Chats.All(c => c.ChatPts == 0));
        Check(input.Chats.Take(2).Select(c => c.ChatId).SequenceEqual(new long[] { 1, 2 }));
        var result = new GetChatDifferencesResponse();
        foreach (var chat in input.Chats)
        {
            var item = new ChatDifferenceResult { ChatId = chat.ChatId, ChatPts = 5, IsFinal = true };
            item.Messages.Add(new Message { ChatId = chat.ChatId, Seq = 50, Version = 5 }); result.Chats.Add(item);
        }
        result.Chats.Add(new ChatDifferenceResult { ChatId = 1, ChatPts = 999, TooLong = true, IsFinal = true });
        result.Chats.Add(new ChatDifferenceResult { ChatId = 999, ChatPts = 5, IsFinal = true });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(result.ToByteArray()) };
    }));
    var sync = new SyncEngine(new BridgeApi(client), store);
    await sync.PrefetchAsync(); await sync.PrefetchAsync();
    Check(calls == 1 && store.Cursor("chat:1") == 5 && store.Cursor("chat:999") == 0 && store.Cursor("chat:3") == 0);
    var window = new HistoryWindow(true); window.Start(store.LatestHistory(1)!);
    Check(window.ReadMessages(store, 1).Single().Seq == 50 && store.Messages(1).Count == 2);
});
await Test("首屏预取忽略取消后的响应及已被打开会话推进的旧快照", async () =>
{
    foreach (bool cancel in new[] { false, true })
    {
        using var store = new LocalStore(":memory:");
        var seed = new Difference { Pts = 1, IsFinal = true }; seed.Dialogs.Add(new Dialog { ChatId = 153, ChatPts = 5 }); store.Apply(seed);
        using var done = new CancellationTokenSource();
        using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ =>
        {
            if (cancel) done.Cancel();
            else store.ApplyChat(153, 6, [new Message { ChatId = 153, Seq = 60, Version = 6 }], []);
            var response = new GetChatDifferencesResponse();
            response.Chats.Add(new ChatDifferenceResult { ChatId = 153, ChatPts = 5, IsFinal = true, TooLong = true });
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) });
        }));
        bool cancelled = false;
        try { await new SyncEngine(new BridgeApi(client), store).PrefetchAsync(done.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        Check(cancelled == cancel && store.Cursor("chat:153") == (cancel ? 0 : 6) && store.LatestHistory(153) is null);
        if (!cancel) Check(store.Messages(153).Single().Seq == 60);
    }
});
await Test("批量补差分组、优先级、缺席会话与非 final 继续分页", async () =>
{
    using var store = new LocalStore(":memory:");
    var difference = new Difference { Pts = 10, IsFinal = true };
    for (long id = 1; id <= 101; id++)
    {
        difference.Dialogs.Add(new Dialog { ChatId = id, DialogPts = 10, ChatPts = 3, Pinned = id == 1, UnreadCount = id == 2 ? 1u : 0u, TopTime = id });
        store.ApplyChat(id, 1, [new Message { ChatId = id, Seq = 1, Version = 1 }], []);
    }
    store.Apply(difference);
    store.SaveLatestHistory(1, new GetHistoryResponse { ChatPts = 1 });
    store.SavePending(new SendMessageRequest { ChatId = 1, ClientRandomId = 77 });
    using var done = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var sizes = new List<int>(); var order = new List<long>(); int singles = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        byte[] response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "GetState": response = new GetStateResponse { Pts = 10 }.ToByteArray(); break;
            case "GetDifference": response = new GetDifferenceResponse { Difference = new Difference { Pts = 10, IsFinal = true } }.ToByteArray(); break;
            case "GetChatDifferences":
                var batch = GetChatDifferencesRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
                sizes.Add(batch.Chats.Count); order.AddRange(batch.Chats.Select(c => c.ChatId));
                Check(batch.PerChatLimit == 30 && batch.Chats.All(c => c.ChatPts == 1));
                var result = new GetChatDifferencesResponse();
                foreach (var chat in batch.Chats.Where(c => c.ChatId != 3))
                {
                    var item = new ChatDifferenceResult { ChatId = chat.ChatId, ChatPts = chat.ChatId == 2 ? 2 : 3, IsFinal = chat.ChatId != 2, TooLong = chat.ChatId == 1 };
                    item.Messages.Add(new Message { ChatId = chat.ChatId, Seq = 3, Version = 3 }); result.Chats.Add(item);
                }
                result.Chats.Add(new ChatDifferenceResult { ChatId = 999, ChatPts = 100, IsFinal = true });
                if (batch.Chats.Any(c => c.ChatId == 1)) result.Chats.Add(new ChatDifferenceResult { ChatId = 1, ChatPts = 100, IsFinal = true });
                response = result.ToByteArray(); break;
            case "GetChatDifference":
                var single = GetChatDifferenceRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
                Check(single.ChatId == 2 && single.ChatPts == 2); singles++;
                response = new GetChatDifferenceResponse { ChatPts = 3, IsFinal = true }.ToByteArray(); break;
            case "Subscribe": done.Cancel(); response = Frame(2, "{}"u8.ToArray()); break;
            default: throw new Exception("意外请求");
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) };
    }));
    await new SyncEngine(new BridgeApi(client), store).RunAsync(done.Token);
    Check(sizes.SequenceEqual(new[] { 100, 1 }) && singles == 1 && order.Take(2).SequenceEqual(new long[] { 1, 2 }));
    Check(store.Cursor("chat:1") == 3 && store.Cursor("chat:2") == 3 && store.Cursor("chat:3") == 1 && store.Cursor("chat:999") == 0);
    Check(store.Messages(1).Single().Seq == 3 && store.LatestHistory(1) is null);
    Check(store.Read("pending", SendMessageRequest.Parser).Single().ClientRandomId == 77);
});
await Test("账号密码登录不带旧令牌，保留密码空格并标识 Windows 设备", async () =>
{
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        Check(request.RequestUri!.AbsolutePath == "/qqbridge.v1.AuthService/Login");
        Check(request.Headers.Authorization is null);
        var input = LoginRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(input.Username == "owner" && input.Password == " test password ");
        Check(input.Platform == "windows" && input.DeviceName == "测试电脑");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new LoginResponse { Token = "fixture-token", AccountId = 1, DeviceId = 8 }.ToByteArray()) };
    }));
    var result = await Authentication.LoginAsync(new BridgeApi(client), " owner ", " test password ", "测试电脑");
    Check(result.Token == "fixture-token" && result.DeviceId == 8);
});
await Test("空密码不发请求，错误密码不生成有效会话", async () =>
{
    int calls = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ =>
    {
        calls++;
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("{\"code\":\"unauthenticated\",\"message\":\"invalid credentials\"}") });
    }));
    bool invalid = false;
    try { await Authentication.LoginAsync(new BridgeApi(client), "owner", "", "测试电脑"); }
    catch (ArgumentException) { invalid = true; }
    Check(invalid && calls == 0);
    bool denied = false;
    try { await Authentication.LoginAsync(new BridgeApi(client), "owner", "wrong", "测试电脑"); }
    catch (RpcException e) { denied = e.Code == "unauthenticated"; }
    Check(denied && calls == 1);
});
await Test("登录地址规范化与无效凭据响应", async () =>
{
    Check(Authentication.ServerUri(" bridge.test ").AbsoluteUri == "https://bridge.test/");
    Check(Authentication.ServerUri("http://localhost:8080").Port == 8080);
    foreach (var value in new[] { "", "http://bridge.test", "https://user:password@bridge.test", "https://bridge.test/?token=x" })
    {
        bool invalid = false; try { Authentication.ServerUri(value); } catch (ArgumentException) { invalid = true; } Check(invalid);
    }
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new LoginResponse().ToByteArray()) })));
    bool rejected = false;
    try { await Authentication.LoginAsync(new BridgeApi(client), "owner", "password", "测试电脑"); } catch (IOException) { rejected = true; }
    Check(rejected);
});
await Test("搜索分页按会话和序号去重，失败可重试", async () =>
{
    int calls = 0;
    var pager = new MessageSearchPager((request, _) =>
    {
        calls++;
        if (calls == 2) throw new IOException("测试断线");
        var response = new SearchMessagesResponse();
        response.Messages.Add(new Message { ChatId = 153, Seq = 8 });
        if (calls == 1) response.Next = new SearchCursor { ChatId = 153, Seq = 8, Time = 9 };
        else { Check(request.Before.Seq == 8); response.Messages.Add(new Message { ChatId = 154, Seq = 8 }); }
        return Task.FromResult(response);
    });
    pager.Reset("关键词", 153); await pager.LoadAsync(default);
    try { await pager.LoadAsync(default); } catch (IOException) { }
    Check(pager.Results.Count == 1 && pager.Next?.Seq == 8 && !pager.Loading);
    await pager.LoadAsync(default);
    Check(pager.Results.Count == 2 && pager.Next is null);
    Check(!await pager.LoadAsync(default) && calls == 3);
});
await Test("旧搜索晚返回不覆盖新搜索，也不解除新请求的忙碌状态", async () =>
{
    var old = new TaskCompletionSource<SearchMessagesResponse>();
    var current = new TaskCompletionSource<SearchMessagesResponse>();
    var pager = new MessageSearchPager((request, _) => request.Query == "旧" ? old.Task : current.Task);
    pager.Reset("旧"); var first = pager.LoadAsync(default);
    pager.Reset("新"); var second = pager.LoadAsync(default);
    var stale = new SearchMessagesResponse(); stale.Messages.Add(new Message { ChatId = 1, Seq = 1 });
    old.SetResult(stale); Check(!await first && pager.Loading && pager.Results.Count == 0);
    var fresh = new SearchMessagesResponse(); fresh.Messages.Add(new Message { ChatId = 2, Seq = 2 });
    current.SetResult(fresh); Check(await second && !pager.Loading && pager.Results.Single().ChatId == 2);
});
await Test("重复搜索游标停止翻页", async () =>
{
    var cursor = new SearchCursor { ChatId = 153, Seq = 2, Time = 5 };
    var pager = new MessageSearchPager((_, _) =>
    {
        var response = new SearchMessagesResponse { Next = cursor }; response.Messages.Add(new Message { ChatId = 153, Seq = 2 });
        return Task.FromResult(response);
    });
    pager.Reset("关键词"); await pager.LoadAsync(default); await pager.LoadAsync(default);
    Check(pager.Results.Count == 1 && pager.Next is null);
});
await Test("聊天预览不自动下载原件，播放优先转码版本", () =>
{
    var media = new MediaInfo { Sha256 = "original" };
    Check(MediaPresentation.PreviewHash(media) == "");
    media.PreviewSha256 = "preview"; Check(MediaPresentation.PreviewHash(media) == "preview");
    media.ThumbSha256 = "thumb"; Check(MediaPresentation.PreviewHash(media) == "thumb");
    Check(MediaPresentation.OpenHash(media) == "original");
    media.PlayableSha256 = "playable"; Check(MediaPresentation.OpenHash(media) == "playable");
    Check(MediaPresentation.StateText(MediaState.Expired).Contains("过期"));
    Check(MediaPresentation.StateText(MediaState.Purged).Contains("清理"));
    return Task.CompletedTask;
});
await Test("历史窗口不会被缓存中的孤立搜索片段拉低分页锚点", () =>
{
    var latest = new HistoryWindow(true);
    var page = new GetHistoryResponse(); page.Messages.Add(new Message { Seq = 900, Time = 900 }); page.Messages.Add(new Message { Seq = 950, Time = 950 });
    latest.Start(page);
    var cached = new[] { new Message { Seq = 10 }, new Message { Seq = 900 }, new Message { Seq = 950 }, new Message { Seq = 960 } };
    Check(latest.First == 900 && latest.Messages(cached).Select(m => m.Seq).SequenceEqual(new long[] { 900, 950, 960 }));
    var older = new GetHistoryResponse(); older.Messages.Add(new Message { Seq = 850 }); latest.Extend(older, true);
    Check(latest.First == 850 && latest.HasOlder);
    latest.Extend(new(), true); Check(!latest.HasOlder && latest.First == 850);
    return Task.CompletedTask;
});
await Test("历史定位窗口只能按已取页扩展，不能混入最新消息", () =>
{
    var window = new HistoryWindow(false);
    var page = new GetHistoryResponse(); page.Messages.Add(new Message { Seq = 10 }); page.Messages.Add(new Message { Seq = 20 }); window.Start(page);
    var cached = new[] { new Message { Seq = 10 }, new Message { Seq = 20 }, new Message { Seq = 30 }, new Message { Seq = 900 } };
    Check(window.Messages(cached).Count == 2 && window.Last == 20);
    var next = new GetHistoryResponse(); next.Messages.Add(new Message { Seq = 30 }); window.Extend(next, false);
    Check(window.Last == 30 && window.Messages(cached).Count == 3 && window.HasNewer);
    window.Extend(next, false); Check(!window.HasNewer);
    return Task.CompletedTask;
});
await Test("历史窗口服务事件不泄漏到不相干片段", () =>
{
    var window = new HistoryWindow(false);
    var page = new GetHistoryResponse(); page.Events.Add(new ChatEvent { Id = 1, Time = 10 }); window.Start(page);
    Check(window.Events(new[] { new ChatEvent { Id = 1 }, new ChatEvent { Id = 2, Time = 900 } }).Single().Id == 1);
    return Task.CompletedTask;
});
await Test("最新历史快照可恢复且 tooLong 会丢弃过期窗口", () =>
{
    using var store = new LocalStore(":memory:");
    var page = new GetHistoryResponse { ChatPts = 8 }; page.Messages.Add(new Message { ChatId = 153, Seq = 900 });
    store.SaveLatestHistory(153, page); Check(store.LatestHistory(153)!.Messages.Single().Seq == 900);
    Check(store.Cursor("chat:153") == 0);
    store.ApplyChat(153, 20, [new Message { ChatId = 153, Seq = 1000 }], [], true);
    Check(store.LatestHistory(153) is null);
    return Task.CompletedTask;
});
await Test("大群历史按窗口读取，保留撤回更新、实时消息和事件隔离", () =>
{
    using var store = new LocalStore(":memory:");
    store.MergeHistory(153, Enumerable.Range(1, 10000).Select(i => new Message { ChatId = 153, Seq = i, Version = 1, Time = i, Text = new string('x', 200) }),
        [new ChatEvent { ChatId = 153, Id = 1, Time = 9999 }, new ChatEvent { ChatId = 153, Id = 2, Time = 20000 }]);
    var page = new GetHistoryResponse();
    page.Messages.Add(Enumerable.Range(9941, 60).Select(i => new Message { ChatId = 153, Seq = i, Time = i }));
    page.Events.Add(new ChatEvent { ChatId = 153, Id = 1, Time = 9999 });
    var latest = new HistoryWindow(true); latest.Start(page);
    var historical = new HistoryWindow(false); historical.Start(page);
    Check(latest.ReadMessages(store, 153).Count == 60);
    store.MergeHistory(153, [new Message { ChatId = 153, Seq = 9999, Version = 2, State = MessageState.Recalled }, new Message { ChatId = 153, Seq = 10001, Version = 1 }], []);
    Check(latest.ReadMessages(store, 153).Count == 61);
    Check(latest.ReadMessages(store, 153).Single(m => m.Seq == 9999).State == MessageState.Recalled);
    Check(historical.ReadMessages(store, 153).Count == 60);
    Check(historical.ReadEvents(store, 153).Single().Id == 1);
    Check(latest.ReadEvents(store, 153).Count == 2);
    var timer = System.Diagnostics.Stopwatch.StartNew();
    for (int i = 0; i < 50; i++) store.Messages(153);
    long full = timer.ElapsedMilliseconds; timer.Restart();
    for (int i = 0; i < 50; i++) latest.ReadMessages(store, 153);
    Console.WriteLine($"合成万条缓存：50 次整群读取 {full} ms，窗口读取 {timer.ElapsedMilliseconds} ms");
    return Task.CompletedTask;
});
await Test("已读请求合并且失败可重试，不回退确认位置", async () =>
{
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var sent = new List<(long Chat, long Seq)>();
    bool fail = false;
    var receipts = new ReadReceiptCoordinator(async (chat, seq, ct) =>
    {
        sent.Add((chat, seq));
        await release.Task.WaitAsync(ct);
        if (fail) throw new IOException("offline");
    });
    var first = receipts.SubmitAsync(153, 100, 90, CancellationToken.None);
    Check(!await receipts.SubmitAsync(153, 101, 90, CancellationToken.None));
    release.SetResult(); Check(await first);
    Check(!await receipts.SubmitAsync(153, 99, 90, CancellationToken.None));
    Check(await receipts.SubmitAsync(153, 101, 90, CancellationToken.None));
    Check(!await receipts.SubmitAsync(153, 102, 102, CancellationToken.None));
    fail = true;
    try { await receipts.SubmitAsync(153, 103, 90, CancellationToken.None); throw new Exception("应失败"); }
    catch (IOException) { }
    fail = false;
    Check(await receipts.SubmitAsync(153, 103, 90, CancellationToken.None));
    Check(await receipts.SubmitAsync(99, 1, 0, CancellationToken.None));
    Check(sent.Count == 5);
});
await Test("提及实体编辑保持用户 ID，重复姓名不串人，局部删除退回文本", () =>
{
    var document = new ComposerDocument(); document.UpdateText("😀你好 ");
    document.Insert(document.Text.Length, 0, "@同名", new OutgoingSegment { MentionUserId = 100 });
    document.Insert(document.Text.Length, 0, "@同名", new OutgoingSegment { MentionUserId = 200 });
    Check(document.Segments().Where(s => s.KindCase == OutgoingSegment.KindOneofCase.MentionUserId).Select(s => s.MentionUserId).SequenceEqual(new long[] { 100, 200 }));
    document.UpdateText("前缀 " + document.Text);
    Check(document.Segments().Count(s => s.KindCase == OutgoingSegment.KindOneofCase.MentionUserId) == 2);
    int first = document.Text.IndexOf("@同名", StringComparison.Ordinal);
    document.UpdateText(document.Text.Remove(first + 1, 1));
    Check(document.Segments().Single(s => s.KindCase == OutgoingSegment.KindOneofCase.MentionUserId).MentionUserId == 200);
    int last = document.Text.IndexOf("@同名", StringComparison.Ordinal);
    document.Insert(last, 3, "@同名", new OutgoingSegment { MentionUserId = 300 });
    Check(document.Segments().Single(s => s.KindCase == OutgoingSegment.KindOneofCase.MentionUserId).MentionUserId == 300);
    document.UpdateText(""); Check(document.Segments().Count == 0);
    return Task.CompletedTask;
});
await Test("结构化草稿恢复保留提及、全体成员与表情，不把手写 @ 误识别", () =>
{
    var original = new[] { new OutgoingSegment { Text = "手写 @张三 " }, new OutgoingSegment { MentionUserId = long.MaxValue }, new OutgoingSegment { MentionAll = true }, new OutgoingSegment { FaceId = "14" } };
    var document = ComposerDocument.FromSegments(original, _ => "张三");
    Check(document.Segments().SequenceEqual(original));
    document.UpdateText(document.Text + " 尾部");
    Check(document.Segments().Count(s => s.KindCase == OutgoingSegment.KindOneofCase.MentionUserId) == 1);
    Check(document.Segments().Last().Text == " 尾部");
    return Task.CompletedTask;
});
await Test("选区删除第一个重名提及时保留第二个用户 ID", () =>
{
    var document = new ComposerDocument();
    document.Insert(0, 0, "@同名", new OutgoingSegment { MentionUserId = 100 });
    document.Insert(document.Text.Length, 0, "@同名", new OutgoingSegment { MentionUserId = 200 });
    document.UpdateText("@同名 ", 0, 4);
    Check(document.Segments().Single(s => s.KindCase == OutgoingSegment.KindOneofCase.MentionUserId).MentionUserId == 200);
    return Task.CompletedTask;
});
await Test("MVVM 单飞与取消后的迟到结果", async () =>
{
    var response = new TaskCompletionSource<GetStateResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
    using var vm = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => response.Task, new ImmediateDispatcher(), false);
    var first = vm.ExecuteAsync(new());
    Check(vm.IsBusy && !await vm.ExecuteAsync(new()));
    vm.Cancel(); response.SetResult(new() { Pts = 42 });
    Check(!await first && vm.State == OperationState.Cancelled && vm.Result is null && !vm.IsBusy);
});
await Test("MVVM 写请求取消区分发送前和发送后", async () =>
{
    int calls = 0;
    using var vm = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => { calls++; return Task.FromResult(new GetStateResponse()); }, new ImmediateDispatcher(), true);
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    Check(!await vm.ExecuteAsync(new(), cancelled.Token) && calls == 0 && !vm.OutcomeUncertain);
    var response = new TaskCompletionSource<GetStateResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
    using var write = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => response.Task, new ImmediateDispatcher(), true);
    var pending = write.ExecuteAsync(new()); write.Cancel(); response.SetResult(new());
    Check(!await pending && write.OutcomeUncertain);
});
await Test("MVVM 销毁后不再发布属性更新", async () =>
{
    var response = new TaskCompletionSource<GetStateResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
    var vm = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => response.Task, new ImmediateDispatcher(), false);
    int notifications = 0; vm.PropertyChanged += (_, _) => notifications++;
    var pending = vm.ExecuteAsync(new()); int before = notifications;
    vm.Dispose(); response.SetResult(new());
    Check(!await pending && notifications == before && vm.Result is null && !vm.CanExecute(new GetStateRequest()));
});
await Test("MVVM 错误可绑定且允许显式重试", async () =>
{
    bool fail = true;
    using var vm = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => fail ? Task.FromException<GetStateResponse>(new IOException("offline")) : Task.FromResult(new GetStateResponse { Pts = 7 }), new ImmediateDispatcher(), false);
    Check(!await vm.ExecuteAsync(new()) && vm.State == OperationState.Failed && vm.Error == "offline");
    fail = false;
    Check(await vm.ExecuteAsync(new()) && vm.Result?.Pts == 7 && vm.Error is null);
});
await Test("SQLite 无版本旧库迁移保留游标并拒绝未来版本", () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open(); using var command = db.CreateCommand();
            command.CommandText = "CREATE TABLE cursors(key TEXT PRIMARY KEY,value INTEGER NOT NULL); INSERT INTO cursors VALUES('global',123);";
            command.ExecuteNonQuery();
        }
        using (var store = new LocalStore(path)) Check(store.Cursor() == 123);
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open(); using var command = db.CreateCommand(); command.CommandText = "PRAGMA user_version";
            Check(Convert.ToInt32(command.ExecuteScalar()) == 2);
            command.CommandText = "PRAGMA user_version=3"; command.ExecuteNonQuery();
        }
        try { using var store = new LocalStore(path); throw new Exception("应拒绝未来版本"); }
        catch (NotSupportedException) { }
    }
    finally { SqliteConnection.ClearAllPools(); File.Delete(path); File.Delete(path + "-wal"); File.Delete(path + "-shm"); }
    return Task.CompletedTask;
});
await Test("后台仓储关闭前排空队列，取消任务不读取数据库", async () =>
{
    using var store = new LocalStore(":memory:");
    var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    using var release = new ManualResetEventSlim();
    var proxy = DispatchProxy.Create<ILocalStore, StoreProxy>();
    int reads = 0, disposes = 0;
    ((StoreProxy)proxy).InvokeStore = (method, args) =>
    {
        if (method.Name == "get_Dialogs")
        {
            Interlocked.Increment(ref reads); entered.TrySetResult();
            if (!release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException();
        }
        if (method.Name == "Dispose") { Interlocked.Increment(ref disposes); return null; }
        return method.Invoke(store, args);
    };
    var repository = new LocalRepository(proxy, ownsStore: true, capacity: 2);
    try
    {
        var first = repository.GetDialogsAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        using var cancel = new CancellationTokenSource();
        var second = repository.GetDialogsAsync(cancel.Token); cancel.Cancel();
        var third = repository.GetPeersAsync();
        var closing = repository.DisposeAsync().AsTask();
        Check(!closing.IsCompleted && disposes == 0 && reads == 1);
        release.Set(); await first; await third; await closing;
        try { await second; throw new Exception("应取消"); } catch (OperationCanceledException) { }
        Check(reads == 1 && disposes == 1);
        try { await repository.GetPeersAsync(); throw new Exception("应拒绝关闭后读取"); } catch (ObjectDisposedException) { }
        await repository.DisposeAsync(); Check(disposes == 1);
    }
    finally { release.Set(); await repository.DisposeAsync(); }
});
await Test("后台仓储按历史窗口查询，返回对象与数据库隔离", async () =>
{
    using var store = new LocalStore(":memory:");
    store.ApplyChat(153, 3, [new Message { ChatId = 153, Seq = 1, Version = 1 }, new Message { ChatId = 153, Seq = 2, Version = 1 }, new Message { ChatId = 153, Seq = 3, Version = 1 }], []);
    await using var repository = new LocalRepository(store);
    var page = await repository.GetMessagesAsync(153, [2], null);
    Check(page.Count == 1 && page[0].Seq == 2);
    page[0].Seq = 100;
    Check((await repository.GetMessagesAsync(153, [2], 2)).Select(m => m.Seq).SequenceEqual(new long[] { 2, 3 }));
    Check((await repository.GetMessagesAsync(999, [2], null)).Count == 0);
});
await Test("会话失效通知只在相关事务提交后发布，消息写入不刷新列表", () =>
{
    using var store = new LocalStore(":memory:");
    int notifications = 0;
    store.DialogsChanged += () => { notifications++; Check(store.DialogRevision == notifications); };
    store.ApplyChat(153, 1, [new Message { ChatId = 153, Seq = 1, Version = 1 }], []);
    store.SavePending(new SendMessageRequest { ChatId = 153, ClientRandomId = 7 });
    var unrelated = new Difference { Pts = 1, IsFinal = true }; unrelated.Peers.Add(new Peer { PeerId = 1, Pts = 1 });
    store.Apply(unrelated);
    Check(notifications == 0);
    var update = new Difference { Pts = 2, IsFinal = true }; update.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 2 });
    store.Apply(update); Check(notifications == 1 && store.Dialogs.Count == 1);
    var removal = new Difference { Pts = 3, IsFinal = true }; removal.Tombstones.Add(new Tombstone { Entity = "chat", Key = "153" });
    store.Apply(removal); Check(notifications == 2 && store.Dialogs.Count == 0);
    store.Reset(); Check(notifications == 3);
    return Task.CompletedTask;
});
await Test("会话资料按账号和类型隔离，资料单独更新保留行与选择", async () =>
{
    using var store = new LocalStore(":memory:");
    await using var repository = new LocalRepository(store);
    await using var vm = new DialogListViewModel(repository, new ImmediateDispatcher());
    var seed = new Difference { Pts = 1, IsFinal = true };
    seed.Dialogs.Add(new Dialog { ChatId = 1, QqAccountId = 1, PeerId = 123, Scene = Scene.Friend, DialogPts = 1 });
    seed.Dialogs.Add(new Dialog { ChatId = 2, QqAccountId = 2, PeerId = 123, Scene = Scene.Friend, DialogPts = 1 });
    seed.Dialogs.Add(new Dialog { ChatId = 3, QqAccountId = 1, PeerId = 123, Scene = Scene.Group, DialogPts = 1 });
    seed.Dialogs.Add(new Dialog { ChatId = 4, QqAccountId = 1, PeerId = long.MaxValue, Scene = Scene.Temp, DialogPts = 1 });
    seed.Peers.Add(new Peer { QqAccountId = 1, PeerId = 123, Kind = PeerKind.User, Name = "昵称", Remark = "备注", AvatarSha256 = "first", Pts = 1 });
    seed.Peers.Add(new Peer { QqAccountId = 2, PeerId = 123, Kind = PeerKind.User, Name = "另一账号", Pts = 1 });
    seed.Peers.Add(new Peer { QqAccountId = 1, PeerId = 123, Kind = PeerKind.Group, Name = "同号群", Pts = 1 });
    store.Apply(seed); Check(await vm.LoadAsync());
    var rows = vm.Items.ToDictionary(r => r.ChatId);
    Check(rows[1].Title == "备注" && rows[1].AvatarSha256 == "first" && rows[2].Title == "另一账号" && rows[3].Title == "同号群" && rows[4].Title == long.MaxValue.ToString());
    await vm.SelectAsync(1);
    long dialogRevision = store.DialogRevision; int notices = 0;
    store.PeersChanged += () => { notices++; Check(store.PeerRevision == 2); };
    var update = new Difference { Pts = 2, IsFinal = true };
    update.Peers.Add(new Peer { QqAccountId = 1, PeerId = 123, Kind = PeerKind.User, Name = "新昵称", AvatarSha256 = "second", Pts = 2 });
    store.Apply(update); Check(await vm.LoadAsync());
    Check(notices == 1 && store.DialogRevision == dialogRevision && ReferenceEquals(rows[1], vm.Items.Single(r => r.ChatId == 1)) && vm.SelectedChatId == 1);
    Check(rows[1].Title == "新昵称" && rows[1].AvatarSha256 == "second" && rows[2].Title == "另一账号" && rows[3].Title == "同号群");
});
await Test("会话列表 MVVM 增量重排保留行和选择，读取失败保留列表", async () =>
{
    using var store = new LocalStore(":memory:");
    await using var repository = new LocalRepository(store);
    await using var vm = new DialogListViewModel(repository, new ImmediateDispatcher());
    var initial = new Difference { Pts = 1, IsFinal = true };
    initial.Dialogs.Add(new Dialog { ChatId = 1, DialogPts = 1, TopTime = 10 });
    initial.Dialogs.Add(new Dialog { ChatId = 2, DialogPts = 1, TopTime = 20 }); store.Apply(initial);
    Check(await vm.LoadAsync() && vm.Items.Select(r => r.ChatId).SequenceEqual(new long[] { 2, 1 }));
    var first = vm.Items.Single(r => r.ChatId == 1);
    await vm.SelectAsync(1);
    int resets = 0;
    ((System.Collections.Specialized.INotifyCollectionChanged)vm.Items).CollectionChanged += (_, e) =>
    { if (e.Action == System.Collections.Specialized.NotifyCollectionChangedAction.Reset) resets++; };
    var change = new Difference { Pts = 2, IsFinal = true };
    change.Dialogs.Add(new Dialog { ChatId = 1, DialogPts = 2, Pinned = true, PinnedAt = 30, UnreadCount = 7 }); store.Apply(change);
    Check(await vm.LoadAsync() && ReferenceEquals(vm.Items[0], first) && vm.SelectedChatId == 1 && first.Snapshot.UnreadCount == 7 && resets == 0);
    var detached = first.Snapshot; detached.UnreadCount = 999;
    Check(first.Snapshot.UnreadCount == 7);
    var removal = new Difference { Pts = 3, IsFinal = true }; removal.Tombstones.Add(new Tombstone { Entity = "chat", Key = "1" }); store.Apply(removal);
    Check(await vm.LoadAsync() && vm.SelectedChatId is null && vm.Items.Single().ChatId == 2 && resets == 0);
    var retained = vm.Items[0];
    await repository.DisposeAsync();
    Check(!await vm.LoadAsync() && vm.Load.State == OperationState.Failed && ReferenceEquals(retained, vm.Items[0]));
});
await Test("联系人 MVVM 保留分组、先读缓存，失败不发布半份列表", async () =>
{
    using var store = new LocalStore(":memory:");
    var cached = new Difference { Pts = 1, IsFinal = true };
    cached.Peers.Add(new Peer { PeerId = 1, Kind = PeerKind.User, IsFriend = true, Name = "缓存好友" });
    cached.Peers.Add(new Peer { PeerId = 10, Kind = PeerKind.User, IsFriend = false });
    store.Apply(cached);
    await using var repository = new LocalRepository(store);
    int stage = 0, refreshes = 0, lists = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        IMessage response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "RefreshContacts":
                refreshes++;
                if (stage == 2) throw new IOException("QQ offline");
                response = new RefreshContactsResponse(); break;
            case "ListFriends":
                lists++;
                var friends = new ListFriendsResponse(); friends.Friends.Add(new Peer { PeerId = stage == 0 ? 2 : 999, Kind = PeerKind.User, IsFriend = true });
                var regular = new FriendCategory { Id = 1, Name = "好友" }; regular.UserIds.Add(2);
                var special = new FriendCategory { Id = 9999, Name = "特别关心", SpecialCare = true }; special.UserIds.Add(2);
                friends.Categories.Add(regular); friends.Categories.Add(special); response = friends; break;
            case "ListGroups":
                lists++; if (stage == 1) throw new IOException("groups offline");
                var groups = new ListGroupsResponse(); groups.Groups.Add(new Peer { PeerId = 3, Kind = PeerKind.Group }); response = groups; break;
            default: throw new Exception("意外请求");
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) });
    }));
    using var vm = new ContactsViewModel(new BridgeApi(client), repository, new ImmediateDispatcher(), repository);
    bool sawCache = false;
    vm.PropertyChanged += (_, _) => { if (vm.Directory.IsCached) sawCache = vm.Directory.Friends.Single().PeerId == 1; };
    Check(await vm.LoadAsync() && sawCache && refreshes == 0 && lists == 2);
    Check(vm.Directory.Friends.Single().PeerId == 2 && vm.Directory.Groups.Single().PeerId == 3 && vm.Directory.Categories.Count == 2);
    Check(vm.Directory.Categories.All(c => c.UserIds.Single() == 2));
    var snapshot = vm.Directory;
    stage = 1; Check(!await vm.LoadAsync(true) && refreshes == 1 && vm.Load.State == OperationState.Failed && ReferenceEquals(snapshot, vm.Directory));
    stage = 2; int before = lists;
    Check(!await vm.LoadAsync(true) && refreshes == 2 && lists == before && ReferenceEquals(snapshot, vm.Directory));
});
await Test("MVVM 响应已排入 UI 队列时取消，仍不发布迟到结果", async () =>
{
    var dispatcher = new QueuedDispatcher();
    using var vm = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => Task.FromResult(new GetStateResponse { Pts = 9 }), dispatcher, false);
    var pending = vm.ExecuteAsync(new());
    (await dispatcher.NextAsync())();
    var publishResult = await dispatcher.NextAsync();
    vm.Cancel(); publishResult();
    (await dispatcher.NextAsync())();
    (await dispatcher.NextAsync())();
    Check(!await pending && vm.State == OperationState.Cancelled && vm.Result is null);
});
await Test("联系人快照事务失败回滚，重开后离线恢复分组且不推进 pts", async () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        using (var store = new LocalStore(path))
        {
            store.Apply(new Difference { Pts = 15, IsFinal = true });
            var friends = new ListFriendsResponse(); friends.Friends.Add(new Peer { PeerId = 2, Kind = PeerKind.User, IsFriend = true });
            var category = new FriendCategory { Id = 9999, Name = "特别关心", SpecialCare = true }; category.UserIds.Add(2); friends.Categories.Add(category);
            var groups = new ListGroupsResponse(); groups.Groups.Add(new Peer { PeerId = 3, Kind = PeerKind.Group });
            await using var repository = new LocalRepository(store);
            await repository.SaveContactsAsync(new(friends, groups));
            using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
            {
                db.Open(); using var command = db.CreateCommand();
                command.CommandText = "CREATE TRIGGER reject_contact_groups BEFORE UPDATE ON records WHEN NEW.kind='contact_groups' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;";
                command.ExecuteNonQuery();
            }
            friends.Friends[0].PeerId = 999;
            try { await repository.SaveContactsAsync(new(friends, groups)); throw new Exception("应写入失败"); } catch (SqliteException) { }
            Check(store.ReadContacts()!.Friends.Friends.Single().PeerId == 2 && store.Cursor() == 15);
        }
        using (var reopened = new LocalStore(path))
        {
            await using var repository = new LocalRepository(reopened);
            using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => throw new IOException("offline")));
            using var vm = new ContactsViewModel(new BridgeApi(client), repository, new ImmediateDispatcher(), repository);
            Check(!await vm.LoadAsync() && vm.Directory.IsCached);
            Check(vm.Directory.Friends.Single().PeerId == 2 && vm.Directory.Groups.Single().PeerId == 3);
            Check(vm.Directory.Categories.Single().SpecialCare && vm.Directory.Categories.Single().UserIds.Single() == 2 && reopened.Cursor() == 15);
            reopened.Reset(); Check(reopened.ReadContacts() is null);
        }
    }
    finally { SqliteConnection.ClearAllPools(); File.Delete(path); File.Delete(path + "-wal"); File.Delete(path + "-shm"); }
});
await Test("提及合并保留新消息，失败可重试，迟到列表不复活已确认记录", async () =>
{
    var listResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    bool fail = true; int marks = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        if (request.RequestUri!.Segments.Last() == "ListUnreadMentions")
        {
            var query = ListUnreadMentionsRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
            Check(query.ChatId == 153 && query.AfterSeq == 4);
            return await listResponse.Task;
        }
        Check(request.RequestUri.Segments.Last() == "MarkMentionsSeen");
        var mark = MarkMentionsSeenRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(mark.ChatId == 153 && mark.Seqs.SequenceEqual(new long[] { 10 })); marks++;
        if (fail) throw new IOException("offline");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new MarkMentionsSeenResponse { Changed = false }.ToByteArray()) };
    }));
    using var vm = new MentionsViewModel(153, false, new BridgeApi(client), new ImmediateDispatcher());
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 10, Flags = 32 }, false, false);
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 20, Flags = 64 }, false, false);
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 30, Flags = 256 }, false, false);
    await vm.NoteIncomingAsync(new Message { ChatId = 999, Seq = 99, Flags = 32 }, false, false);
    Check(vm.Items.Select(i => i.Seq).SequenceEqual(new long[] { 30, 10 }));
    var loading = vm.LoadAsync(4);
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 20, Flags = 64 }, false, false);
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 30, Flags = 256 }, false, false);
    Check(!await vm.MarkSeenAsync([10, 10, -1]) && vm.Items.Any(i => i.Seq == 10));
    fail = false; Check(await vm.MarkSeenAsync([10]) && vm.Items.All(i => i.Seq != 10));
    var list = new ListUnreadMentionsResponse();
    list.Mentions.Add(new UnreadMention { Seq = 10, Flags = 32 });
    list.Mentions.Add(new UnreadMention { Seq = 5, Flags = 32 });
    list.Mentions.Add(new UnreadMention { Seq = 5, Flags = 256 });
    listResponse.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(list.ToByteArray()) });
    Check(await loading && vm.Items.Select(i => i.Seq).SequenceEqual(new long[] { 30, 5 }));
    Check(vm.Items.Single(i => i.Seq == 5).Flags == 288);
    Check(await vm.MarkSeenAsync([10]) && marks == 2);
    await vm.SetIncludeAllAsync(true); Check(vm.Items.Select(i => i.Seq).SequenceEqual(new long[] { 30, 20, 5 }));
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 20, State = MessageState.Recalled }, false, false);
    Check(vm.Items.All(i => i.Seq != 20));
});
await Test("Subscribe 未缓存消息和跨设备会话更新均通知功能页失效", async () =>
{
    using var store = new LocalStore(":memory:");
    using var done = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    var changes = new List<long>();
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        byte[] bytes = request.RequestUri!.Segments.Last() switch
        {
            "GetState" => new GetStateResponse().ToByteArray(),
            "GetDifference" => new GetDifferenceResponse { Difference = new Difference { IsFinal = true } }.ToByteArray(),
            "Subscribe" => Frame(0, new SubscribeResponse { ChatMessage = new ChatMessageUpdate { ChatId = 153, ChatPts = 8,
                Message = new Message { ChatId = 153, Seq = 50, Flags = 32 } } }.ToByteArray())
                .Concat(Frame(0, new SubscribeResponse { Dialog = new DialogUpdate { Pts = 1, Dialog = new Dialog { ChatId = 153, DialogPts = 1, UnreadMentions = 0 } } }.ToByteArray()))
                .Concat(Frame(0, new SubscribeResponse { Tombstone = new TombstoneUpdate { Pts = 2, Tombstone = new Tombstone { Entity = "dialog", Key = "153" } } }.ToByteArray()))
                .Concat(Frame(2, "{}"u8.ToArray())).ToArray(),
            _ => throw new Exception("意外请求")
        };
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
    }));
    var sync = new SyncEngine(new BridgeApi(client), store);
    sync.ChatInvalidated += chat => { changes.Add(chat); if (changes.Count == 3) done.Cancel(); };
    await sync.RunAsync(done.Token);
    Check(changes.SequenceEqual(new long[] { 153, 153, 153 }) && store.Cursor() == 2 && store.Cursor("chat:153") == 0 && store.Messages(153).Count == 0 && store.ReadDialog(153) is null);
});
await Test("提及刷新清除跨设备已读，满页保留范围外旧项", async () =>
{
    var response = new ListUnreadMentionsResponse();
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new ByteArrayContent(response.ToByteArray()) })));
    using var vm = new MentionsViewModel(153, true, new BridgeApi(client), new ImmediateDispatcher());
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 2, Flags = 32 }, false, false);
    await vm.NoteIncomingAsync(new Message { ChatId = 153, Seq = 500, Flags = 32 }, false, false);
    for (int seq = 100; seq < 300; seq++) response.Mentions.Add(new UnreadMention { Seq = seq, Flags = 32 });
    Check(await vm.LoadAsync(0));
    Check(vm.Items.Count == 201 && vm.Items.Any(i => i.Seq == 2) && vm.Items.All(i => i.Seq != 500));
    response = new ListUnreadMentionsResponse(); response.Mentions.Add(new UnreadMention { Seq = 101, Flags = 256 });
    Check(await vm.LoadAsync(50));
    Check(vm.Items.Select(i => i.Seq).SequenceEqual(new long[] { 101, 2 }) && vm.Items[0].Flags == 256);
    response = new ListUnreadMentionsResponse();
    Check(await vm.LoadAsync(0) && vm.Items.Count == 0);
});
await Test("反应用户名单保持请求目标，去重并回退号码，失败保留已有名单", async () =>
{
    bool fail = false;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var query = ListReactionUsersRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(query.ChatId == 153 && query.Seq == 99 && query.EmojiId == "14");
        if (fail) throw new IOException("offline");
        var response = new ListReactionUsersResponse();
        response.Users.Add(new ReactionUser { UserId = long.MaxValue });
        response.Users.Add(new ReactionUser { UserId = 2 }); response.Users.Add(new ReactionUser { UserId = 2, Name = "群名片" });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    using var vm = new ReactionUsersViewModel(153, 99, "14", new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadAsync() && vm.Users.Count == 2 && vm.Users[0].DisplayName == "9223372036854775807" && vm.Users[1].DisplayName == "群名片");
    var previous = vm.Users; fail = true;
    Check(!await vm.LoadAsync() && ReferenceEquals(previous, vm.Users) && vm.Load.State == OperationState.Failed);
});
await Test("共享媒体按 ord 保留同消息多图，更新重叠项并停止重复游标", async () =>
{
    int calls = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var query = ListSharedMediaRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()); calls++;
        Check(query.ChatId == 153 && query.Sort == "time_desc" && query.Offset == 0 && query.BeforeSeq == (calls == 1 ? 0 : 10));
        var response = new ListSharedMediaResponse { NextBeforeSeq = 10 };
        response.Items.Add(new SharedMedia { Seq = 10, Kind = MediaKind.Image, Size = (ulong)calls, Segment = new Segment { Image = new ImageSegment { Media = new MediaInfo { Ord = 0 } } } });
        if (calls == 1) response.Items.Add(new SharedMedia { Seq = 10, Kind = MediaKind.Image, Segment = new Segment { Image = new ImageSegment { Media = new MediaInfo { Ord = 1 } } } });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    using var vm = new SharedMediaViewModel(153, [MediaKind.Image], SharedMediaOrder.Newest, 0, new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadMoreAsync() && vm.Items.Count == 2 && vm.HasMore);
    Check(await vm.LoadMoreAsync() && vm.Items.Count == 2 && vm.Items[0].Size == 2 && !vm.HasMore && vm.PaginationError is not null);
    Check(!await vm.LoadMoreAsync() && calls == 2);
});
await Test("共享媒体发送者筛选使用 offset，空页继续且失败保持游标可重试", async () =>
{
    int calls = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var query = ListSharedMediaRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()); calls++;
        Check(query.SenderId == 123 && query.BeforeSeq == 0 && query.Offset == (calls == 1 ? 0 : 80));
        if (calls == 2) throw new IOException("offline");
        var response = new ListSharedMediaResponse { NextOffset = calls == 1 ? 80 : 0 };
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    using var vm = new SharedMediaViewModel(153, [], SharedMediaOrder.Newest, 123, new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadMoreAsync() && vm.Items.Count == 0 && vm.HasMore);
    Check(!await vm.LoadMoreAsync() && vm.HasMore);
    Check(await vm.LoadMoreAsync() && !vm.HasMore && calls == 3);
});
await Test("通知偏好区分请求确认与同步值，迟到响应不覆盖新版本", async () =>
{
    var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    bool fail = false; var policies = new List<string>();
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var body = await request.Content!.ReadAsByteArrayAsync();
        if (request.RequestUri!.Segments.Last() == "SetMentionAllNotify")
        {
            var query = SetMentionAllNotifyRequest.Parser.ParseFrom(body); Check(query.ChatId == 153 && !query.Enabled);
            return await release.Task;
        }
        if (request.RequestUri.Segments.Last() == "SetNotifyPolicy")
        {
            var query = SetNotifyPolicyRequest.Parser.ParseFrom(body); Check(query.ChatId == 153); policies.Add(query.Policy);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SetNotifyPolicyResponse { Changed = false }.ToByteArray()) };
        }
        var pinned = SetPinnedRequest.Parser.ParseFrom(body); Check(pinned.ChatId == 153 && pinned.Pinned);
        if (fail) throw new IOException("offline");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SetPinnedResponse { Changed = true }.ToByteArray()) };
    }));
    using var vm = new DialogPreferencesViewModel(new Dialog { ChatId = 153, DialogPts = 10, MentionAllNotify = true, NotifyPolicy = "default" }, new BridgeApi(client), new ImmediateDispatcher());
    var pending = vm.SetMentionAll.ExecuteAsync(new(false));
    await vm.ApplyDialogAsync(new Dialog { ChatId = 153, DialogPts = 12, MentionAllNotify = true, NotifyPolicy = "all", Pinned = true });
    release.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SetMentionAllNotifyResponse { Changed = true }.ToByteArray()) });
    Check(await pending && vm.MentionAllNotify && vm.NotifyPolicy == "all" && vm.Pinned);
    await vm.ApplyDialogAsync(new Dialog { ChatId = 153, DialogPts = 11, MentionAllNotify = false, NotifyPolicy = "muted" });
    await vm.ApplyDialogAsync(new Dialog { ChatId = 999, DialogPts = 100, MentionAllNotify = false });
    Check(vm.MentionAllNotify && vm.NotifyPolicy == "all");
    foreach (var policy in Enum.GetValues<NotificationPolicy>()) Check(await vm.SetPolicy.ExecuteAsync(new(policy)));
    Check(policies.SequenceEqual(new[] { "default", "all", "mentions", "muted", "archived" }) && vm.NotifyPolicy == "all");
    fail = true; Check(!await vm.SetPinned.ExecuteAsync(new(true)) && vm.Pinned);
    await vm.ApplyDialogAsync(new Dialog { ChatId = 153, DialogPts = 13, MentionAllNotify = false, NotifyPolicy = "muted" });
    Check(!vm.MentionAllNotify && !vm.Pinned && vm.NotifyPolicy == "muted");
});
await Test("贴纸分批准备保留缺失项可重试，迟到列表不撤销就绪与刷新标记", async () =>
{
    var hashes = Enumerable.Range(0, 61).Select(n => n.ToString("x32")).ToArray();
    var sizes = new List<int>(); bool missing = true, delayList = false; int adds = 0;
    var delayed = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    byte[] ListBytes()
    {
        var list = new ListStickersResponse();
        foreach (var md5 in hashes) list.Stickers.Add(new Sticker { Md5 = md5, Desc = "保留描述", Market = true });
        return list.ToByteArray();
    }
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var bytes = await request.Content!.ReadAsByteArrayAsync();
        switch (request.RequestUri!.Segments.Last())
        {
            case "ListStickers":
                if (delayList) return await delayed.Task;
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(ListBytes()) };
            case "PrepareStickers":
                var query = PrepareStickersRequest.Parser.ParseFrom(bytes); sizes.Add(query.Md5.Count);
                var response = new PrepareStickersResponse();
                foreach (var md5 in query.Md5.Where(m => !missing || m != hashes.Last())) response.Stickers.Add(new Sticker { Md5 = md5, Sha256 = new string('a', 64), ThumbSha256 = new string('b', 64) });
                response.Stickers.Add(new Sticker { Md5 = new string('f', 32), Sha256 = new string('a', 64) });
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
            case "AddSticker":
                adds++; Check(AddStickerRequest.Parser.ParseFrom(bytes).Sha256 == new string('a', 64));
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new AddStickerResponse().ToByteArray()) };
            default: throw new Exception("意外请求");
        }
    }));
    using var vm = new StickerCatalogViewModel(new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadAsync() && vm.Items.Count == 61);
    Check(await vm.PrepareAsync(hashes.Concat([hashes[0]])) && sizes.SequenceEqual(new[] { 60, 1 }));
    Check(vm.Missing.Single() == hashes.Last() && vm.Items.Count(i => i.Sha256.Length > 0) == 60);
    Check(vm.Items.All(i => i.Market && i.Desc == "保留描述"));
    missing = false; Check(await vm.PrepareAsync(vm.Missing) && vm.Missing.Count == 0 && vm.Items.All(i => i.Sha256.Length == 64));
    Check(!await vm.AddAsync("bad hash") && adds == 0);
    delayList = true; var pending = vm.LoadAsync();
    Check(await vm.AddAsync(new string('A', 64)) && vm.NeedsRefresh && adds == 1);
    delayed.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(ListBytes()) });
    Check(await pending && vm.NeedsRefresh && vm.Items.All(i => i.Sha256.Length == 64));
    delayList = false; Check(await vm.LoadAsync(true) && !vm.NeedsRefresh);
});
await Test("会话存储详情保留完整字节数和策略语义，错误响应不覆盖快照", async () =>
{
    int calls = 0; bool wrongChat = false;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        calls++; var query = GetChatStorageRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(query.ChatId == 153 && query.TopLimit == 20);
        var response = new GetChatStorageResponse
        {
            Summary = new ChatStorage { ChatId = wrongChat ? 999 : 153, LogicalBytes = ulong.MaxValue, ExclusiveBytes = 7, HotBytes = 8, ColdBytes = 9 },
            Policy = new EffectiveStoragePolicy { KeepOriginalDays = -1, ColdAfterDays = -1, HotQuotaBytes = 0 }
        };
        response.Kinds.Add(new KindStorage { Kind = MediaKind.Image, LogicalBytes = ulong.MaxValue, PurgedCount = 3 });
        response.Largest.Add(new StoredItem { Sha256 = new string('a', 64), Size = ulong.MaxValue, Shared = true, FirstSeq = 0, Tier = "cold" });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    using var vm = new ChatStorageViewModel(153, new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadAsync());
    var detail = vm.Detail!;
    Check(detail.Summary.LogicalBytes == ulong.MaxValue && detail.Summary.ExclusiveBytes == 7 && detail.Summary.HotBytes == 8 && detail.Summary.ColdBytes == 9);
    Check(detail.Policy.KeepOriginalDays == -1 && detail.Policy.ColdAfterDays == -1 && detail.Policy.HotQuotaBytes == 0);
    Check(detail.Largest.Single().Shared && detail.Largest.Single().FirstSeq == 0 && detail.Kinds.Single().PurgedCount == 3);
    vm.Load.Result!.Summary.LogicalBytes = 0; Check(detail.Summary.LogicalBytes == ulong.MaxValue);
    Check(!await vm.LoadAsync(101) && calls == 1 && ReferenceEquals(detail, vm.Detail));
    wrongChat = true;
    Check(!await vm.LoadAsync() && calls == 2 && ReferenceEquals(detail, vm.Detail));
});
await Test("群文件夹删除后使目录失效，迟到列表不能恢复旧文件 ID", async () =>
{
    int deletes = 0; bool delayedLoad = false, failDelete = true;
    var late = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    HttpResponseMessage Listing()
    {
        var response = new ListGroupFilesResponse(); response.Folders.Add(new GroupFolder { Id = "folder-1", Name = "测试目录" });
        response.Files.Add(new GroupFile { Id = "ephemeral-file-id", Name = "测试文件" });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var body = await request.Content!.ReadAsByteArrayAsync();
        if (request.RequestUri!.Segments.Last() == "ListGroupFiles")
        {
            var query = ListGroupFilesRequest.Parser.ParseFrom(body); Check(query.GroupId == 521409608 && query.FolderId == "");
            return delayedLoad ? await late.Task : Listing();
        }
        var deletion = DeleteGroupFolderRequest.Parser.ParseFrom(body); Check(deletion.GroupId == 521409608 && deletion.FolderId == "folder-1");
        deletes++; if (failDelete) throw new IOException("unknown outcome");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new DeleteGroupFolderResponse().ToByteArray()) };
    }));
    using var vm = new GroupFilesViewModel(521409608, "", new BridgeApi(client), new ImmediateDispatcher());
    Check(!await vm.DeleteFolder.ExecuteAsync(new("folder-1")) && deletes == 0);
    Check(await vm.LoadAsync() && !vm.NeedsReload && vm.Files.Count == 1);
    Check(!await vm.DeleteFolder.ExecuteAsync(new("unknown")) && deletes == 0 && !vm.NeedsReload);
    delayedLoad = true; var pending = vm.LoadAsync();
    Check(!await vm.DeleteFolder.ExecuteAsync(new("folder-1")) && deletes == 1 && vm.NeedsReload && vm.Files.Count == 0);
    late.SetResult(Listing()); Check(await pending && vm.NeedsReload && vm.Files.Count == 0);
    delayedLoad = false; failDelete = false;
    Check(await vm.LoadAsync() && !vm.NeedsReload);
    Check(await vm.DeleteFolder.ExecuteAsync(new("folder-1")) && deletes == 2 && vm.NeedsReload && vm.Folders.Count == 0);
});
await Test("QQ 登录查询与刷新独立于密码登录，刷新失败不保留旧二维码", async () =>
{
    int loads = 0, refreshes = 0; bool failRefresh = true, loggedIn = false;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        IMessage response;
        if (request.RequestUri!.Segments.Last() == "RefreshQqLoginQrcode")
        {
            refreshes++; if (failRefresh) throw new IOException("unavailable");
            response = new RefreshQqLoginQrcodeResponse { QrcodeUrl = "https://fixture.invalid/new" };
        }
        else
        {
            Check(request.RequestUri.Segments.Last() == "GetQqLogin"); loads++;
            response = new GetQqLoginResponse { LoggedIn = loggedIn, Offline = !loggedIn, Phase = "fixture-phase", QrcodeUrl = "https://fixture.invalid/current", Error = "diagnostic" };
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) });
    }));
    using var vm = new QqLoginViewModel(new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.Load.ExecuteAsync(new()) && vm.State!.Offline && vm.State.Phase == "fixture-phase" && vm.State.Error == "diagnostic");
    Check(!await vm.RefreshQr.ExecuteAsync(new()) && vm.State!.QrcodeUrl.Length == 0 && loads == 1 && refreshes == 1);
    failRefresh = false;
    Check(await vm.RefreshQr.ExecuteAsync(new()) && loads == 2 && refreshes == 2 && vm.State!.QrcodeUrl == "https://fixture.invalid/current");
    loggedIn = true;
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    await vm.ObserveWhileVisibleAsync(timeout.Token);
    Check(vm.State!.LoggedIn && loads == 3 && refreshes == 2 && !timeout.IsCancellationRequested);
    vm.Dispose(); await vm.ObserveWhileVisibleAsync(CancellationToken.None); Check(loads == 3);
});
await Test("QQ 登录页关闭不发布迟到二维码，账号退出等待查询与刷新且不继续后续请求", async () =>
{
    foreach (bool refresh in new[] { false, true })
    {
        int calls = 0;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var handler = new Handler(async request =>
        {
            Interlocked.Increment(ref calls);
            Check(request.RequestUri!.Segments.Last() == (refresh ? "RefreshQqLoginQrcode" : "GetQqLogin"));
            started.TrySetResult(); await release.Task;
            IMessage response = refresh
                ? new RefreshQqLoginQrcodeResponse { QrcodeUrl = "fixture-qr" }
                : new GetQqLoginResponse { QrcodeUrl = "fixture-qr", Offline = true };
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
        });
        var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
        using var vm = new QqLoginViewModel(session.GetQqLoginAsync, session.RefreshQqLoginQrcodeAsync, new ImmediateDispatcher());
        Task pending = refresh ? vm.RefreshQr.ExecuteAsync(new()) : vm.ObserveWhileVisibleAsync(CancellationToken.None);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5)); vm.Dispose();
        var closing = session.DisposeAsync().AsTask();
        Check(!closing.IsCompleted && !handler.IsDisposed);
        release.SetResult(); await pending.WaitAsync(TimeSpan.FromSeconds(5)); await closing.WaitAsync(TimeSpan.FromSeconds(5));
        Check(handler.IsDisposed && calls == 1 && vm.State is null);
        await vm.ObserveWhileVisibleAsync(CancellationToken.None);
        Check(!await vm.RefreshQr.ExecuteAsync(new()) && calls == 1);
    }
});
await Test("通话恢复与临时事件合并，终态不被迟到响应复活", async () =>
{
    var response = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        Check(request.RequestUri!.Segments.Last() == "GetActiveCall"); return response.Task;
    }));
    using var vm = new CallStateViewModel(new BridgeApi(client), new ImmediateDispatcher());
    var restoring = vm.RestoreAsync();
    await vm.ApplyUpdateAsync(new Call { Id = "a", Phase = CallPhase.Ringing, InviteAt = 100 });
    await vm.ApplyUpdateAsync(new Call { Id = "a", Phase = CallPhase.Connected, InviteAt = 100, ConnectedAt = 101 });
    await vm.ApplyUpdateAsync(new Call { Id = "a", Phase = CallPhase.Accepting, InviteAt = 100 });
    Check(vm.Active?.Phase == CallPhase.Connected);
    await vm.ApplyUpdateAsync(new Call { Id = "a", Phase = CallPhase.Ended, InviteAt = 100, EndedAt = 102, EndReason = 7 });
    response.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new GetActiveCallResponse { Call = new Call { Id = "a", Phase = CallPhase.Connected } }.ToByteArray()) });
    Check(await restoring && vm.Active is null && vm.LastEnded?.EndReason == 7);
    await vm.ApplyUpdateAsync(new Call { Id = "a", Phase = CallPhase.Ringing, InviteAt = 100 }); Check(vm.Active is null);
    await vm.ApplyUpdateAsync(new Call { Id = "b", Phase = CallPhase.Ringing, InviteAt = 200 });
    await vm.ApplyUpdateAsync(new Call { Id = "old", Phase = CallPhase.Ringing, InviteAt = 50 });
    await vm.ApplyUpdateAsync(new Call { Id = "a", Phase = CallPhase.Ended, InviteAt = 100, EndedAt = 102 });
    Check(vm.Active?.Id == "b");
    vm.Dispose(); await vm.ApplyUpdateAsync(new Call { Id = "b", Phase = CallPhase.Ended, EndedAt = 203 });
    Check(vm.Active?.Id == "b");
});
await Test("好友删除修正全部分组，失败保留缓存，旧修订不能写回好友", async () =>
{
    using var store = new LocalStore(":memory:"); store.Apply(new Difference { Pts = 10, IsFinal = true });
    await using var repository = new LocalRepository(store);
    var friends = new ListFriendsResponse(); friends.Friends.Add(new Peer { PeerId = 2, IsFriend = true, Kind = PeerKind.User });
    foreach (int id in new[] { 1, 9999 }) { var category = new FriendCategory { Id = id, SpecialCare = id == 9999 }; category.UserIds.Add(2); friends.Categories.Add(category); }
    var groups = new ListGroupsResponse(); groups.Groups.Add(new Peer { PeerId = 3, Kind = PeerKind.Group });
    await repository.SaveContactsAsync(new(friends, groups));
    bool fail = true; int deletes = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        IMessage response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "ListFriends": response = friends; break;
            case "ListGroups": response = groups; break;
            case "DeleteFriend":
                Check(DeleteFriendRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()).UserId == 2);
                deletes++; if (fail) throw new IOException("offline"); response = new DeleteFriendResponse(); break;
            default: throw new Exception("意外请求");
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    using var vm = new ContactsViewModel(new BridgeApi(client), repository, new ImmediateDispatcher(), repository);
    Check(await vm.LoadAsync());
    long oldRevision = await repository.GetContactsRevisionAsync();
    Check(!await vm.DeleteFriend.ExecuteAsync(new(2)) && vm.Directory.Friends.Count == 1 && (await repository.ReadContactsAsync())!.Friends.Friends.Count == 1);
    fail = false; Check(await vm.DeleteFriend.ExecuteAsync(new(2)) && deletes == 2);
    Check(vm.Directory.Friends.Count == 0 && vm.Directory.Categories.All(c => c.UserIds.Count == 0) && vm.Directory.Groups.Single().PeerId == 3);
    Check(!await repository.TrySaveContactsAsync(new(friends, groups), oldRevision));
    Check((await repository.ReadContactsAsync())!.Friends.Friends.Count == 0 && store.Cursor() == 10);
    Check(!await vm.DeleteFriend.ExecuteAsync(new(2)) && deletes == 2);
    long beforeReset = await repository.GetContactsRevisionAsync(); store.Reset();
    Check(!await repository.TrySaveContactsAsync(new(friends, groups), beforeReset));
});
await Test("好友删除确认即退出仍落盘，关闭等待迟到旧列表且重开后不复活好友", async () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    ClientSessionRuntime? session = null;
    try
    {
        var friends = new ListFriendsResponse(); friends.Friends.Add(new Peer { PeerId = 2, Kind = PeerKind.User, IsFriend = true });
        var category = new FriendCategory { Id = 1 }; category.UserIds.Add(2); friends.Categories.Add(category);
        var groups = new ListGroupsResponse(); groups.Groups.Add(new Peer { PeerId = 3, Kind = PeerKind.Group });
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int friendReads = 0, deletes = 0;
        var handler = new Handler(async request =>
        {
            IMessage response;
            switch (request.RequestUri!.Segments.Last())
            {
                case "ListFriends":
                    if (Interlocked.Increment(ref friendReads) == 2) { started.SetResult(); await release.Task; }
                    response = friends; break;
                case "ListGroups": response = groups; break;
                case "DeleteFriend": Interlocked.Increment(ref deletes); response = new DeleteFriendResponse(); break;
                default: throw new Exception("意外请求");
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
        });
        session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", path, new ImmediateDispatcher(), handler: handler);
        Check(await session.Contacts.LoadAsync());
        var oldLoad = session.Contacts.LoadAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Task? closing = null;
        session.Contacts.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ContactsViewModel.ConfirmedDeletedUserId) && session.Contacts.ConfirmedDeletedUserId == 2)
                closing = session.DisposeAsync().AsTask();
        };
        await session.Contacts.DeleteFriend.ExecuteAsync(new(2));
        Check(closing is not null && !closing.IsCompleted && !handler.IsDisposed);
        release.SetResult(); Check(!await oldLoad.WaitAsync(TimeSpan.FromSeconds(5)));
        await closing!.WaitAsync(TimeSpan.FromSeconds(5)); Check(handler.IsDisposed && deletes == 1 && friendReads == 2);
        using var reopened = new LocalStore(path);
        var saved = reopened.ReadContacts();
        Check(saved is not null && saved.Friends.Friends.Count == 0 && saved.Friends.Categories.Single().UserIds.Count == 0
            && saved.Groups.Groups.Single().PeerId == 3);
    }
    finally
    {
        release.TrySetResult(); if (session is not null) await session.DisposeAsync();
        SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix);
    }
});
await Test("通话编排先检查音频，入会失败收尾，接听和挂断不泄漏房间凭据", async () =>
{
    int starts = 0, answers = 0, hangups = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        IMessage response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "StartCall": starts++; response = new StartCallResponse { Call = new Call { Id = "out", Phase = CallPhase.Ringing }, LivekitUrl = "wss://fixture.invalid", LivekitToken = "fixture-token", Room = "room" }; break;
            case "AnswerCall": answers++; response = new AnswerCallResponse { Call = new Call { Id = "in", Phase = CallPhase.Accepting }, LivekitUrl = "wss://fixture.invalid", LivekitToken = "fixture-token", Room = "room" }; break;
            case "HangupCall": hangups++; response = new HangupCallResponse { Call = new Call { Id = answers > 0 ? "in" : "out", Phase = CallPhase.Ended } }; break;
            default: throw new Exception("意外请求");
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) });
    }));
    var api = new BridgeApi(client); using var state = new CallStateViewModel(api, new ImmediateDispatcher());
    var audio = new TestCallAudio { FailPrepare = true }; var coordinator = new CallCoordinator(api, audio, state);
    try { await coordinator.StartAsync(123); throw new Exception("应拒绝无音频呼出"); } catch (NotSupportedException) { }
    Check(starts == 0 && audio.Leaves == 1);
    audio.FailPrepare = false; audio.FailJoin = true;
    try { await coordinator.StartAsync(123); throw new Exception("应入会失败"); } catch (IOException) { }
    Check(starts == 1 && hangups == 1 && audio.Leaves == 2);
    audio.FailJoin = false;
    var call = await coordinator.AnswerAsync("in"); Check(call.Id == "in" && answers == 1 && audio.Joins == 2);
    try { await coordinator.StartAsync(456); throw new Exception("应拒绝第二通本机通话"); } catch (InvalidOperationException) { }
    Check(starts == 1);
    await coordinator.HangupAsync("in"); Check(hangups == 2 && audio.Leaves == 3);
});
await Test("通话结束事件取消入会，忽略取消的音频返回后仍离开", async () =>
{
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        Check(request.RequestUri!.Segments.Last() == "StartCall");
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new StartCallResponse { Call = new Call { Id = "late", Phase = CallPhase.Ringing }, LivekitUrl = "wss://fixture.invalid", LivekitToken = "fixture-token", Room = "room" }.ToByteArray()) });
    }));
    var api = new BridgeApi(client); using var state = new CallStateViewModel(api, new ImmediateDispatcher());
    var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var audio = new TestCallAudio { JoinWait = async () => { entered.SetResult(); await release.Task; } };
    var coordinator = new CallCoordinator(api, audio, state);
    var starting = coordinator.StartAsync(123);
    await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var ending = coordinator.ApplyUpdateAsync(new Call { Id = "late", Phase = CallPhase.Ended });
    release.SetResult();
    try { await starting; throw new Exception("应取消入会"); } catch (OperationCanceledException) { }
    await ending; Check(audio.Leaves == 1 && state.Active is null);
});
await Test("异步关闭操作等待忽略取消的请求完成且不发布结果", async () =>
{
    var late = new TaskCompletionSource<GetStateResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
    var vm = new RpcOperationViewModel<GetStateRequest, GetStateResponse>((_, _) => late.Task, new ImmediateDispatcher(), false);
    var executing = vm.ExecuteAsync(new());
    var closing = vm.DisposeAsync().AsTask();
    Check(!closing.IsCompleted && !await vm.ExecuteAsync(new()));
    late.SetResult(new GetStateResponse { Pts = 5 });
    Check(!await executing); await closing;
    Check(vm.Result is null && !vm.IsBusy);
});
await Test("正常关闭排空本地草稿而不依赖网络，重开可恢复最终副本", async () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        int requests = 0;
        var handler = new Handler(_ => { requests++; throw new Exception("本地保存不应联网"); });
        var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", path, new ImmediateDispatcher(), handler: handler);
        var draft = new SaveDraftRequest { ChatId = 153, ReplyToSeq = 12 }; draft.Segments.Add(new OutgoingSegment { Text = "最后的输入" });
        var saved = runtime.PersistDraftAsync(draft);
        draft.Segments[0].Text = "外部改写";
        await runtime.DisposeAsync(); await saved;
        Check(requests == 0 && handler.IsDisposed);
        using var store = new LocalStore(path);
        Check(store.ReadLocalDraft(153)!.Segments.Single().Text == "最后的输入" && store.ReadLocalDraft(153)!.ReplyToSeq == 12);
    }
    finally { SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
});
await Test("草稿先持久化后顺序同步，旧确认不能清除新内容", async () =>
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var firstReply = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    var sent = new List<string>();
    var handler = new Handler(async request =>
    {
        Check(request.RequestUri!.Segments.Last() == "SaveDraft");
        var input = SaveDraftRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        sent.Add(input.Segments.Single().Text);
        if (sent.Count == 1) { started.TrySetResult(); return await firstReply.Task; }
        return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{\"code\":\"unavailable\",\"message\":\"fixture\"}") };
    });
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    var old = new SaveDraftRequest { ChatId = 153 }; old.Segments.Add(new OutgoingSegment { Text = "旧内容" });
    var newer = new SaveDraftRequest { ChatId = 153, ReplyToSeq = 12 }; newer.Segments.Add(new OutgoingSegment { Text = "新内容" });
    var first = runtime.SaveDraftAsync(old);
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var second = runtime.SaveDraftAsync(newer);
    Check((await runtime.Repository.GetLocalDraftAsync(153))!.Equals(newer) && sent.Count == 1);
    var d = new Difference { Pts = 1, IsFinal = true };
    var dialog = new Dialog { ChatId = 153, DialogPts = 1, Draft = new Draft() }; dialog.Draft.Segments.Add(old.Segments); d.Dialogs.Add(dialog);
    runtime.LegacyStore.Apply(d);
    firstReply.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SaveDraftResponse { Changed = true }.ToByteArray()) });
    await first;
    try { await second; throw new Exception("应同步失败"); } catch (RpcException) { }
    Check(sent.SequenceEqual(new[] { "旧内容", "新内容" }) && (await runtime.Repository.GetLocalDraftAsync(153))!.Equals(newer));
    d.Pts = 2; dialog.DialogPts = 2; dialog.Draft.Segments.Clear(); dialog.Draft.Segments.Add(newer.Segments); dialog.Draft.ReplyToSeq = 12;
    runtime.LegacyStore.Apply(d);
    Check(await runtime.Repository.GetLocalDraftAsync(153) is null);
});
await Test("本地草稿重开和重置后保留，空草稿覆盖层等待同步清除", () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        var draft = new SaveDraftRequest { ChatId = 153, ReplyToSeq = 12 }; draft.Segments.Add(new OutgoingSegment { Text = "离线草稿" });
        using (var store = new LocalStore(path)) { store.SaveLocalDraft(draft); store.Reset(); }
        using (var store = new LocalStore(path))
        {
            Check(store.ReadLocalDraft(153)!.Equals(draft));
            store.SaveLocalDraft(new SaveDraftRequest { ChatId = 153 });
            Check(store.ReadLocalDraft(153) is { Segments.Count: 0 });
            var d = new Difference { Pts = 1, IsFinal = true }; d.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 1 }); store.Apply(d);
            Check(store.ReadLocalDraft(153) is null && store.Cursor() == 1);
        }
    }
    finally { SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
    return Task.CompletedTask;
});
await Test("附件上传按内容哈希秒传或续传，拒绝越界偏移、跨站地址和错误确认", async () =>
{
    foreach (var mode in new[] { "exists", "resume", "offset", "origin", "ack" })
    {
        byte[] content = [1, 2, 3, 4, 5]; int patches = 0;
        string hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(content)).ToLowerInvariant();
        var handler = new Handler(async request =>
        {
            if (request.RequestUri!.Segments.Last() == "PrepareUpload")
            {
                var input = PrepareUploadRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
                Check(input.Sha256 == hash && input.Size == 5 && input.Name == "附件.bin" && input.Mime == "application/octet-stream");
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new PrepareUploadResponse
                { Exists = mode == "exists", Offset = mode == "offset" ? 6ul : 2ul, UploadUrl = mode == "origin" ? "https://other.test/upload/1" : "/upload/1" }.ToByteArray()) };
            }
            Check(request.Method == HttpMethod.Patch && request.RequestUri.AbsolutePath == "/upload/1");
            Check(request.Headers.Authorization?.Parameter == "fixture-token" && request.Headers.GetValues("Upload-Offset").Single() == "2");
            Check((await request.Content!.ReadAsByteArrayAsync()).SequenceEqual(new byte[] { 3, 4, 5 })); patches++;
            var response = new HttpResponseMessage(HttpStatusCode.NoContent); response.Headers.Add("Upload-Offset", mode == "ack" ? "4" : "5"); return response;
        });
        await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
        using var stream = new MemoryStream(content); stream.Position = 4;
        bool failed = false;
        try { var media = await runtime.UploadMediaAsync(stream, "附件.bin", ""); Check(media.Sha256 == hash && media.Name == "附件.bin"); }
        catch (IOException) { failed = true; }
        Check(failed == (mode is "offset" or "origin" or "ack") && patches == (mode is "resume" or "ack" ? 1 : 0) && stream.CanRead);
    }
});
await Test("发送先落库，错误确认保留重试，成功使用同一幂等 ID 且不推进 pts", async () =>
{
    ClientSessionRuntime? session = null; int attempts = 0;
    var handler = new Handler(async request =>
    {
        Check(request.RequestUri!.Segments.Last() == "SendMessage");
        var input = SendMessageRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(session!.LegacyStore.Read("pending", SendMessageRequest.Parser).Single().ClientRandomId == 77);
        Check(input.ClientRandomId == 77 && input.Segments.Single().Text == "测试内容");
        attempts++;
        var entry = new OutboxEntry { ChatId = attempts == 1 ? 999 : 153, ClientRandomId = 77, Pts = 50, State = OutboxState.Pending };
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SendMessageResponse { Entry = entry }.ToByteArray()) };
    });
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    session = runtime; runtime.LegacyStore.Apply(new Difference { Pts = 5, IsFinal = true });
    var request = new SendMessageRequest { ChatId = 153, ClientRandomId = 77 }; request.Segments.Add(new OutgoingSegment { Text = "测试内容" });
    try { await runtime.SendMessageAsync(request); throw new Exception("应拒绝错误确认"); } catch (IOException) { }
    Check(runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Count == 1 && runtime.LegacyStore.Read("outbox", OutboxEntry.Parser).Count == 0);
    await runtime.SendMessageAsync(request);
    Check(attempts == 2 && runtime.LegacyStore.Cursor() == 5 && runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Count == 0);
    Check(runtime.LegacyStore.Read("outbox", OutboxEntry.Parser).Single().ClientRandomId == 77);
});
await Test("同一消息发送单飞且请求持有副本，失败后不丢内容", async () =>
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var response = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    var handler = new Handler(async request =>
    {
        var input = SendMessageRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(input.Segments.Single().Text == "原文"); started.TrySetResult(); return await response.Task;
    });
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    var request = new SendMessageRequest { ChatId = 153, ClientRandomId = 77 }; request.Segments.Add(new OutgoingSegment { Text = "原文" });
    var sending = runtime.SendMessageAsync(request); request.Segments[0].Text = "外部修改";
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    try { await runtime.SendMessageAsync(request); throw new Exception("应拒绝重复发送"); } catch (InvalidOperationException) { }
    Check(runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Single().Segments.Single().Text == "原文");
    response.SetResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{\"code\":\"unavailable\",\"message\":\"fixture\"}") });
    try { await sending; throw new Exception("应发送失败"); } catch (RpcException) { }
    Check(runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Single().ClientRandomId == 77);
    try { await runtime.QueueMessageAsync(request); throw new Exception("应拒绝改变重试内容"); } catch (InvalidOperationException) { }
    Check(runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Single().Segments.Single().Text == "原文");
});
await Test("后台时间线快照固定窗口与账号内会话，定位页不混入待发送项", async () =>
{
    using var store = new LocalStore(":memory:");
    await using var repository = new LocalRepository(store);
    var page = new GetHistoryResponse(); page.Messages.Add(new Message { ChatId = 153, Seq = 50, Version = 1, Time = 50 });
    store.MergeHistory(153, page.Messages, []);
    store.MergeHistory(153, [new Message { ChatId = 153, Seq = 1, Version = 1, Time = 1 }, new Message { ChatId = 153, Seq = 51, Version = 2, Time = 51 }], []);
    store.SavePending(new SendMessageRequest { ChatId = 153, ClientRandomId = 7 });
    store.SavePending(new SendMessageRequest { ChatId = 999, ClientRandomId = 8 });
    var window = new HistoryWindow(true); window.Start(page);
    var query = window.Capture(153);
    var older = new GetHistoryResponse(); older.Messages.Add(new Message { ChatId = 153, Seq = 1 }); window.Extend(older, true);
    var snapshot = await repository.GetTimelineAsync(query);
    Check(snapshot.Messages.Select(m => m.Seq).SequenceEqual(new long[] { 50, 51 }) && snapshot.Pending.Single().ClientRandomId == 7);
    store.AcceptPending(new OutboxEntry { ChatId = 153, ClientRandomId = 7, Pts = 1, State = OutboxState.Pending });
    snapshot = await repository.GetTimelineAsync(query);
    Check(snapshot.Pending.Count == 0 && snapshot.Outbox.Single().ClientRandomId == 7);
    var positioned = new HistoryWindow(false); positioned.Start(page);
    snapshot = await repository.GetTimelineAsync(positioned.Capture(153));
    Check(snapshot.Messages.Single().Seq == 50 && snapshot.Pending.Count == 0 && snapshot.Outbox.Count == 0);
    snapshot.Messages[0].Text = "修改副本";
    Check(store.Messages(153).Single(m => m.Seq == 50).Text.Length == 0);
});
await Test("运行时历史加载保存首屏，定位翻页不替换窗口也不推进同步游标", async () =>
{
    bool wrongChat = false;
    var handler = new Handler(async request =>
    {
        Check(request.RequestUri!.Segments.Last() == "GetHistory");
        var input = GetHistoryRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        var page = new GetHistoryResponse { ChatPts = 99 };
        page.Messages.Add(new Message { ChatId = wrongChat ? 999 : input.ChatId, Seq = input.HasAnchorSeq ? 10 : 50, Version = 99 });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(page.ToByteArray()) };
    });
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    runtime.LegacyStore.ApplyChat(153, 5, [], []);
    await runtime.GetHistoryAsync(new() { ChatId = 153, Direction = HistoryDirection.Older, Limit = 60 });
    Check((await runtime.Repository.GetLatestHistoryAsync(153))!.Messages.Single().Seq == 50);
    await runtime.GetHistoryAsync(new() { ChatId = 153, Direction = HistoryDirection.Older, AnchorSeq = 50, Limit = 60 });
    Check(runtime.LegacyStore.Cursor("chat:153") == 5 && runtime.LegacyStore.Messages(153).Count == 2);
    Check((await runtime.Repository.GetLatestHistoryAsync(153))!.Messages.Single().Seq == 50);
    wrongChat = true;
    try { await runtime.GetHistoryAsync(new() { ChatId = 153, Direction = HistoryDirection.Older }); throw new Exception("应拒绝串会话"); } catch (IOException) { }
    Check(runtime.LegacyStore.Messages(999).Count == 0 && (await runtime.Repository.GetLatestHistoryAsync(153))!.Messages.Single().ChatId == 153);
});
await Test("页面取消后迟到的历史响应不写入缓存", async () =>
{
    using var cancel = new CancellationTokenSource();
    var handler = new Handler(_ =>
    {
        cancel.Cancel();
        var page = new GetHistoryResponse { ChatPts = 99 }; page.Messages.Add(new Message { ChatId = 153, Seq = 50, Version = 99 });
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(page.ToByteArray()) });
    });
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    try { await runtime.GetHistoryAsync(new() { ChatId = 153, Direction = HistoryDirection.Older }, cancel.Token); throw new Exception("应取消历史请求"); } catch (OperationCanceledException) { }
    Check(runtime.LegacyStore.Messages(153).Count == 0 && await runtime.Repository.GetLatestHistoryAsync(153) is null);
});
await Test("账号退出等待聊天补差结束，迟到响应不写库且关闭后拒绝新加载", async () =>
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var late = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    var handler = new Handler(request =>
    {
        Check(request.RequestUri!.Segments.Last() == "GetChatDifference");
        started.TrySetResult(); return late.Task;
    });
    var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    int changes = 0; runtime.LegacyStore.Changed += () => changes++;
    var loading = runtime.LoadChatAsync(153);
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var closing = runtime.DisposeAsync().AsTask();
    Check(!closing.IsCompleted && !handler.IsDisposed);
    try { await runtime.LoadChatAsync(153); throw new Exception("应拒绝关闭中的加载"); } catch (ObjectDisposedException) { }
    await Task.Run(async () => { while (runtime.Dialogs.Load.CanExecute(new DialogListQuery())) await Task.Yield(); }).WaitAsync(TimeSpan.FromSeconds(5));
    late.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new GetChatDifferenceResponse { ChatPts = 5, IsFinal = true }.ToByteArray()) });
    try { await loading; throw new Exception("应取消补差"); } catch (OperationCanceledException) { }
    await closing.WaitAsync(TimeSpan.FromSeconds(5));
    Check(handler.IsDisposed && changes == 0);
});
await Test("会话组合根连接同步临时事件并按生命周期关闭，重复启动不创建第二条流", async () =>
{
    int states = 0, restores = 0;
    var restoreStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var restoreResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    var listReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var delivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var handler = new Handler(request =>
    {
        byte[] response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "GetActiveCall":
                Interlocked.Increment(ref restores); restoreStarted.TrySetResult(); return restoreResponse.Task;
            case "GetState": states++; response = new GetStateResponse().ToByteArray(); break;
            case "GetDifference":
                var diff = new Difference { Pts = 1, IsFinal = true }; diff.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 1 });
                response = new GetDifferenceResponse { Difference = diff }.ToByteArray(); break;
            case "GetChatDifferences": response = new GetChatDifferencesResponse().ToByteArray(); break;
            case "Subscribe":
                response = Frame(0, new SubscribeResponse { Call = new CallUpdate { Call = new Call { Id = "runtime-call", Phase = CallPhase.Ringing, InviteAt = 100 } } }.ToByteArray()).Concat(Frame(2, "{}"u8.ToArray())).ToArray(); break;
            default: throw new Exception("意外请求");
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) });
    });
    var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    runtime.Calls.PropertyChanged += (_, _) => { if (runtime.Calls.Active?.Id == "runtime-call") delivered.TrySetResult(); };
    ((System.Collections.Specialized.INotifyCollectionChanged)runtime.Dialogs.Items).CollectionChanged += (_, _) =>
    { if (runtime.Dialogs.Items.Any(r => r.ChatId == 153)) listReady.TrySetResult(); };
    runtime.Start(); runtime.Start();
    await Task.WhenAll(delivered.Task, listReady.Task).WaitAsync(TimeSpan.FromSeconds(5));
    await restoreStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var closing = runtime.DisposeAsync().AsTask();
    Check(!closing.IsCompleted && !handler.IsDisposed);
    restoreResponse.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new GetActiveCallResponse { Call = new Call { Id = "old-call", Phase = CallPhase.Ringing, InviteAt = 1 } }.ToByteArray()) });
    await closing.WaitAsync(TimeSpan.FromSeconds(5)); await runtime.DisposeAsync();
    Check(restores == 1 && runtime.Calls.Active?.Id == "runtime-call");
    Check(states == 1 && handler.IsDisposed);
    try { runtime.Start(); throw new Exception("应拒绝关闭后启动"); } catch (ObjectDisposedException) { }
    try { await runtime.Repository.GetPeersAsync(); throw new Exception("应拒绝关闭后查询"); } catch (ObjectDisposedException) { }
});
await Test("会话启动通话恢复失败不阻塞消息订阅，错误保留供重试", async () =>
{
    var subscribed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var handler = new Handler(request =>
    {
        byte[] response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "GetActiveCall": return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                { Content = new StringContent("{\"code\":\"unavailable\",\"message\":\"fixture\"}") });
            case "GetState": response = new GetStateResponse().ToByteArray(); break;
            case "GetDifference": response = new GetDifferenceResponse { Difference = new Difference { IsFinal = true } }.ToByteArray(); break;
            case "Subscribe": subscribed.TrySetResult(); response = Frame(2, "{}"u8.ToArray()); break;
            default: throw new Exception("意外请求");
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) });
    });
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(), handler: handler);
    var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    runtime.Calls.Restore.PropertyChanged += (_, _) =>
    {
        if (runtime.Calls.Restore.State == OperationState.Failed) failed.TrySetResult();
    };
    runtime.Start();
    await Task.WhenAll(subscribed.Task, failed.Task).WaitAsync(TimeSpan.FromSeconds(5));
    Check(runtime.Calls.Active is null && runtime.Calls.Restore.ErrorCode == "unavailable");
});
await Test("Windows 通知过滤自身、前台、已读与历史消息", () =>
{
    var message = new Message { ChatId = 153, Seq = 8, Time = 101, State = MessageState.Normal, SenderId = 2, Text = "hello" };
    var dialog = new Dialog { ChatId = 153, NotifyPolicy = "all" };
    MessageNotification? Evaluate(Message m, Dialog d, IReadOnlySet<long>? own = null, long? foreground = null)
        => new MessageNotificationPolicy(100).Evaluate(m, d, "测试群", own ?? new HashSet<long>(), foreground, 102);
    Check(Evaluate(message, dialog) is not null);
    Check(Evaluate(message, dialog, new HashSet<long> { 2 }) is null);
    Check(Evaluate(message, dialog, foreground: 153) is null);
    var read = dialog.Clone(); read.ReadInboxMaxSeq = 8; Check(Evaluate(message, read) is null);
    var old = message.Clone(); old.Time = 100; Check(Evaluate(old, dialog) is null);
    var future = message.Clone(); future.Time = 200; Check(Evaluate(future, dialog) is null);
    var recalled = message.Clone(); recalled.State = MessageState.Unspecified; Check(Evaluate(recalled, dialog) is null);
    return Task.CompletedTask;
});
await Test("Windows 通知免打扰、提及策略与重复编辑抑制", () =>
{
    var message = new Message { ChatId = 153, Seq = 8, Time = 101, State = MessageState.Normal, SenderId = 2, Flags = 32 };
    var dialog = new Dialog { ChatId = 153, NotifyPolicy = "mentions" };
    var own = new HashSet<long>();
    MessageNotification? Evaluate() => new MessageNotificationPolicy(100).Evaluate(message, dialog, "群", own, null, 102);
    Check(Evaluate() is not null);
    message.Flags = 256; Check(Evaluate() is not null);
    message.Flags = 64; Check(Evaluate() is null);
    dialog.MentionAllNotify = true; Check(Evaluate() is not null);
    dialog.NotifyPolicy = "muted"; Check(Evaluate() is null);
    dialog.NotifyPolicy = "archived"; Check(Evaluate() is null);
    dialog.NotifyPolicy = "all";
    var policy = new MessageNotificationPolicy(100);
    Check(policy.Evaluate(message, dialog, "群", own, 153, 102) is null);
    message.Text = "修改后的消息";
    Check(policy.Evaluate(message, dialog, "群", own, null, 102) is null);
    message.Seq++;
    Check(policy.Evaluate(message, dialog, "群", own, null, 102) is not null);
    Check(policy.Evaluate(message, dialog, "群", own, null, 102) is null);
    return Task.CompletedTask;
});
await Test("发送 ID 遵守后端安全整数边界，非法 ID 不落库也不请求", async () =>
{
    for (int i = 0; i < 10000; i++) Check(MessageIdentity.Create() is > 0 and <= MessageIdentity.MaxValue);
    int calls = 0;
    await using var runtime = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture-token", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(_ => { calls++; throw new Exception("非法请求不应到达网络"); }));
    foreach (long id in new[] { 0L, -1L, MessageIdentity.MaxValue + 1, long.MaxValue })
    {
        var request = new SendMessageRequest { ChatId = 153, ClientRandomId = id }; request.Segments.Add(new OutgoingSegment { Text = "内容" });
        try { await runtime.SendMessageAsync(request); throw new Exception("应拒绝越界 ID"); } catch (ArgumentException) { }
    }
    Check(calls == 0 && runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Count == 0);
    var valid = new SendMessageRequest { ChatId = 153, ClientRandomId = MessageIdentity.MaxValue };
    valid.Segments.Add(new OutgoingSegment { Text = "边界" }); await runtime.QueueMessageAsync(valid);
    Check(runtime.LegacyStore.Read("pending", SendMessageRequest.Parser).Single().Equals(valid));
});
await Test("服务端确认后同一 ID 仍不可修改会话、回复和消息内容", () =>
{
    using var store = new LocalStore(":memory:");
    var original = new SendMessageRequest { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 8 };
    original.Segments.Add(new OutgoingSegment { Text = "原文" });
    var accepted = new OutboxEntry { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 8, Pts = 9, State = OutboxState.Failed };
    accepted.Segments.Add(original.Segments); store.AcceptPending(accepted);
    foreach (int change in new[] { 0, 1, 2 })
    {
        var altered = original.Clone();
        if (change == 0) altered.ChatId = 999;
        if (change == 1) altered.ReplyToSeq = 9;
        if (change == 2) altered.Segments[0].Text = "新文";
        try { store.SavePending(altered); throw new Exception("应拒绝复用 ID"); } catch (InvalidOperationException) { }
        Check(store.Read("pending", SendMessageRequest.Parser).Count == 0);
    }
    store.SavePending(original);
    Check(store.Read("pending", SendMessageRequest.Parser).Single().Equals(original));
    return Task.CompletedTask;
});
await Test("启动恢复旧版越界发送 ID，保留内容且二次重开不再换 ID", () =>
{
    string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        var old = new SendMessageRequest { ChatId = 153, ClientRandomId = long.MaxValue, ReplyToSeq = 9 };
        old.Segments.Add(new OutgoingSegment { Text = "未发出的文字" });
        old.Segments.Add(new OutgoingSegment { File = new OutgoingMedia { Sha256 = new string('a', 64), Name = "附件.bin" } });
        var valid = old.Clone(); valid.ClientRandomId = 77;
        using (var store = new LocalStore(path)) { store.SavePending(old); store.SavePending(valid); }
        long recoveredId;
        using (var store = new LocalStore(path))
        {
            var items = store.Read("pending", SendMessageRequest.Parser);
            Check(items.Count == 2 && items.Any(x => x.Equals(valid)));
            var recovered = items.Single(x => x.ClientRandomId != 77);
            recoveredId = recovered.ClientRandomId;
            Check(recoveredId is > 0 and <= MessageIdentity.MaxValue);
            recovered.ClientRandomId = old.ClientRandomId; Check(recovered.Equals(old));
            Check(store.Cursor() == 0 && store.Read("outbox", OutboxEntry.Parser).Count == 0);
        }
        using (var store = new LocalStore(path))
            Check(store.Read("pending", SendMessageRequest.Parser).Select(x => x.ClientRandomId).ToHashSet().SetEquals([77, recoveredId]));
    }
    finally { SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
    return Task.CompletedTask;
});
await Test("旧发送 ID 恢复失败完整回滚，已有服务端记录不擅自换 ID", () =>
{
    string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        var original = new SendMessageRequest { ChatId = 153, ClientRandomId = long.MaxValue };
        original.Segments.Add(new OutgoingSegment { Text = "保留原文" });
        using (var store = new LocalStore(path)) { store.SavePending(original); }
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path }.ToString()))
        {
            db.Open(); using var command = db.CreateCommand();
            command.CommandText = "CREATE TRIGGER fail_recovery BEFORE DELETE ON records WHEN OLD.kind='pending' BEGIN SELECT RAISE(ABORT, 'fixture'); END";
            command.ExecuteNonQuery();
        }
        try { using var store = new LocalStore(path); throw new Exception("应恢复失败"); } catch (SqliteException) { }
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path }.ToString()))
        {
            db.Open(); using var command = db.CreateCommand();
            command.CommandText = "SELECT data FROM records WHERE kind='pending'";
            using (var reader = command.ExecuteReader())
            { Check(reader.Read() && SendMessageRequest.Parser.ParseFrom((byte[])reader[0]).Equals(original)); Check(!reader.Read()); }
            command.CommandText = "DROP TRIGGER fail_recovery"; command.ExecuteNonQuery();
            var accepted = new OutboxEntry { ChatId = 153, ClientRandomId = long.MaxValue, Pts = 8, State = OutboxState.Sent };
            command.CommandText = "INSERT INTO records(kind,key,chat,version,data) VALUES('outbox',$key,153,8,$data)";
            command.Parameters.AddWithValue("$key", long.MaxValue.ToString()); command.Parameters.AddWithValue("$data", accepted.ToByteArray());
            command.ExecuteNonQuery();
        }
        using (var store = new LocalStore(path)) Check(store.Read("pending", SendMessageRequest.Parser).Single().Equals(original));
    }
    finally { SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
    return Task.CompletedTask;
});
await Test("同步先确认发送后 RPC 迟到不倒退，缓存重置不复活待发送项", () =>
{
    using var store = new LocalStore(":memory:");
    var pending = new SendMessageRequest { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 3 };
    pending.Segments.Add(new OutgoingSegment { Text = "原请求" }); store.SavePending(pending);
    var sent = new OutboxEntry { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 3, State = OutboxState.Sent, Pts = 12, Seq = 42 };
    sent.Segments.Add(pending.Segments);
    var difference = new Difference { Pts = 12, IsFinal = true }; difference.Outbox.Add(sent); store.Apply(difference);
    Check(store.Read("pending", SendMessageRequest.Parser).Count == 0 && store.Cursor() == 12);
    var older = sent.Clone(); older.State = OutboxState.Pending; older.Pts = 10; older.Seq = 0;
    store.AcceptPending(older);
    Check(store.Read("outbox", OutboxEntry.Parser).Single().Equals(sent) && store.Cursor() == 12);
    store.Reset(); Check(store.Read("pending", SendMessageRequest.Parser).Count == 0);
    return Task.CompletedTask;
});
await Test("同步发送确认不删除内容冲突或缺少版本的本地请求", () =>
{
    using var store = new LocalStore(":memory:");
    var pending = new SendMessageRequest { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 3 };
    pending.Segments.Add(new OutgoingSegment { Text = "需要保留" }); store.SavePending(pending);
    var entry = new OutboxEntry { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 3, State = OutboxState.Sent, Pts = 1 };
    entry.Segments.Add(pending.Segments);
    foreach (int kind in new[] { 0, 1, 2, 3 })
    {
        var bad = entry.Clone();
        if (kind == 0) bad.ChatId = 999;
        if (kind == 1) bad.ReplyToSeq = 4;
        if (kind == 2) bad.Segments[0].Text = "其他内容";
        if (kind == 3) bad.Pts = 0;
        var difference = new Difference { Pts = 1 }; difference.Outbox.Add(bad); store.Apply(difference);
        Check(store.Read("pending", SendMessageRequest.Parser).Single().Equals(pending));
    }
    return Task.CompletedTask;
});
await Test("同步收尾失败回滚发件箱、待发送记录和全局游标", () =>
{
    string path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        using var store = new LocalStore(path);
        var request = new SendMessageRequest { ChatId = 153, ClientRandomId = 77 }; request.Segments.Add(new OutgoingSegment { Text = "事务测试" });
        store.SavePending(request); store.Apply(new Difference { Pts = 3 });
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path }.ToString());
        db.Open(); using var command = db.CreateCommand();
        command.CommandText = "CREATE TRIGGER fail_confirmation BEFORE DELETE ON records WHEN OLD.kind='pending' BEGIN SELECT RAISE(ABORT,'fixture'); END";
        command.ExecuteNonQuery();
        var sent = new OutboxEntry { ChatId = 153, ClientRandomId = 77, Pts = 4, State = OutboxState.Sent }; sent.Segments.Add(request.Segments);
        var difference = new Difference { Pts = 4 }; difference.Outbox.Add(sent);
        try { store.Apply(difference); throw new Exception("应回滚"); } catch (SqliteException) { }
        Check(store.Cursor() == 3 && store.Read("outbox", OutboxEntry.Parser).Count == 0);
        Check(store.Read("pending", SendMessageRequest.Parser).Single().Equals(request));
        command.CommandText = "DROP TRIGGER fail_confirmation"; command.ExecuteNonQuery();
        store.Apply(difference);
        Check(store.Cursor() == 4 && store.Read("pending", SendMessageRequest.Parser).Count == 0);
    }
    finally { SqliteConnection.ClearAllPools(); foreach (var suffix in new[] { "", "-wal", "-shm" }) File.Delete(path + suffix); }
    return Task.CompletedTask;
});
await Test("群文件修改使用当前目录 ID 和元数据，失败及部分失败后必须重载", async () =>
{
    int writes = 0, loads = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var body = await request.Content!.ReadAsByteArrayAsync(); IMessage response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "ListGroupFiles":
                loads++; var list = new ListGroupFilesResponse(); list.Files.Add(new GroupFile { Id = "file-" + loads, Name = "原名", Size = 19 }); response = list; break;
            case "RenameGroupFile":
                writes++; var rename = RenameGroupFileRequest.Parser.ParseFrom(body);
                Check(rename.GroupId == 123 && rename.FileId == "file-1" && rename.FolderId == "folder" && rename.Name == "原名" && rename.Size == 19 && rename.NewName == "新名");
                throw new IOException("模拟回包丢失");
            case "MoveGroupFiles":
                writes++; var move = MoveGroupFilesRequest.Parser.ParseFrom(body);
                Check(move.FromFolderId == "folder" && move.ToFolderId == "" && move.FileIds.Single() == "file-2");
                var moved = new MoveGroupFilesResponse(); moved.Failures.Add(new GroupFileOpFailure { Reason = "没有权限" }); response = moved; break;
            case "DeleteGroupFiles":
                writes++; var delete = DeleteGroupFilesRequest.Parser.ParseFrom(body);
                Check(delete.GroupId == 123 && delete.FileIds.Single() == "file-3"); response = new DeleteGroupFilesResponse(); break;
            default: throw new Exception("意外调用");
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    using var vm = new GroupFilesViewModel(123, "folder", new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadAsync());
    Check(!await vm.RenameFile.ExecuteAsync(new("missing", "新名")) && writes == 0 && !vm.NeedsReload);
    Check(!await vm.RenameFile.ExecuteAsync(new("file-1", " ")) && writes == 0);
    Check(!await vm.RenameFile.ExecuteAsync(new("file-1", " 新名 ")) && writes == 1 && vm.NeedsReload && vm.Files.Count == 0);
    Check(!await vm.DeleteFile.ExecuteAsync(new("file-1")) && writes == 1);
    Check(await vm.LoadAsync() && !await vm.DeleteFile.ExecuteAsync(new("file-1")) && writes == 1);
    Check(await vm.MoveFile.ExecuteAsync(new("file-2", "")) && writes == 2 && vm.NeedsReload);
    Check(vm.MoveFile.Result!.Failures.Single().Reason == "没有权限");
    Check(await vm.LoadAsync() && await vm.DeleteFile.ExecuteAsync(new("file-3")) && writes == 3 && vm.NeedsReload);
    Check(await vm.LoadAsync() && !await vm.CreateFolder.ExecuteAsync(new("子文件夹")) && writes == 3);
});
await Test("群文件不同修改操作互斥，新建仅限根目录且离开后不接受结果", async () =>
{
    int writes = 0;
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        if (request.RequestUri!.Segments.Last() == "ListGroupFiles")
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new ListGroupFilesResponse().ToByteArray()) };
        Check(request.RequestUri.Segments.Last() == "CreateGroupFolder");
        var create = CreateGroupFolderRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(create.GroupId == 123 && create.Name == "目录"); writes++; started.TrySetResult(); return await release.Task;
    }));
    using var vm = new GroupFilesViewModel(123, "", new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadAsync());
    var creating = vm.CreateFolder.ExecuteAsync(new(" 目录 "));
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    Check(!await vm.DeleteFile.ExecuteAsync(new("file")) && writes == 1);
    vm.Dispose();
    release.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new CreateGroupFolderResponse().ToByteArray()) });
    Check(!await creating && vm.NeedsReload && vm.Files.Count == 0);
});
await Test("贴纸准备后生成表情图片发送请求，未就绪或非法目标不得发送", async () =>
{
    string md5 = new('a', 32), sha = new('b', 64);
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        IMessage response;
        if (request.RequestUri!.Segments.Last() == "ListStickers")
        {
            var list = new ListStickersResponse(); list.Stickers.Add(new Sticker { Md5 = md5, Desc = "[测试表情]", Market = true }); response = list;
        }
        else
        {
            var prepared = new PrepareStickersResponse(); prepared.Stickers.Add(new Sticker { Md5 = md5, Sha256 = sha }); response = prepared;
        }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) });
    }));
    using var vm = new StickerCatalogViewModel(new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadAsync());
    try { vm.CreateMessage(md5, 153, 77); throw new Exception("未准备不得发送"); } catch (InvalidOperationException) { }
    Check(await vm.PrepareAsync([md5]));
    var request = vm.CreateMessage(md5.ToUpperInvariant(), 153, 77, 42);
    Check(request.ChatId == 153 && request.ClientRandomId == 77 && request.ReplyToSeq == 42);
    Check(request.Segments.Single().Image is { Sticker: true, Summary: "[测试表情]" } image && image.Sha256 == sha);
    request.Segments[0].Image.Sha256 = "外部修改";
    Check(vm.CreateMessage(md5, 153, 78).Segments[0].Image.Sha256 == sha);
    try { vm.CreateMessage(md5, 0, 77); throw new Exception("无效目标"); } catch (ArgumentException) { }
    try { vm.CreateMessage(md5, 153, long.MaxValue); throw new Exception("无效 ID"); } catch (ArgumentException) { }
    try { vm.CreateMessage(new string('c', 32), 153, 77); throw new Exception("未知表情"); } catch (InvalidOperationException) { }
});
await Test("清理执行固定预估条件，旧确认失效且失败后不能重复执行", async () =>
{
    int plans = 0, executions = 0; bool failPlan = false;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var bytes = await request.Content!.ReadAsByteArrayAsync();
        if (request.RequestUri!.Segments.Last() == "PlanCleanup")
        {
            plans++; var input = PlanCleanupRequest.Parser.ParseFrom(bytes); Check(input.ChatId == 153);
            if (failPlan) throw new IOException("预估失败");
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new PlanCleanupResponse { FreedBytes = ulong.MaxValue }.ToByteArray()) };
        }
        executions++; var execute = ExecuteCleanupRequest.Parser.ParseFrom(bytes);
        Check(execute.ChatId == 153 && execute.OlderThanDays == 90 && execute.Kinds.Single() == MediaKind.Video);
        throw new IOException("执行回包丢失");
    }));
    using var vm = new CleanupViewModel(153, new BridgeApi(client), new ImmediateDispatcher());
    Check(!await vm.Execute.ExecuteAsync(new(Guid.NewGuid())) && executions == 0);
    Check(await vm.Preview.ExecuteAsync(new(30, MediaKind.Image))); var old = vm.Preview.Result!;
    Check(old.Estimate.FreedBytes == ulong.MaxValue);
    Check(await vm.Preview.ExecuteAsync(new(90, MediaKind.Video))); var current = vm.Preview.Result!;
    Check(!await vm.Execute.ExecuteAsync(new(old.Id)) && executions == 0);
    current.Estimate.FreedBytes = 0;
    Check(!await vm.Execute.ExecuteAsync(new(current.Id)) && executions == 1 && vm.Execute.OutcomeUncertain);
    Check(!await vm.Execute.ExecuteAsync(new(current.Id)) && executions == 1);
    Check(await vm.Preview.ExecuteAsync(new(30))); old = vm.Preview.Result!;
    failPlan = true; Check(!await vm.Preview.ExecuteAsync(new(31)));
    Check(!await vm.Execute.ExecuteAsync(new(old.Id)) && executions == 1);
    int before = plans;
    Check(!await vm.Preview.ExecuteAsync(new(0)) && !await vm.Preview.ExecuteAsync(new(30, MediaKind.Unspecified)) && plans == before);
});
await Test("清理预估取消后迟到结果不能生成可执行确认", async () =>
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        Check(request.RequestUri!.Segments.Last() == "PlanCleanup"); started.TrySetResult(); return release.Task;
    }));
    using var vm = new CleanupViewModel(153, new BridgeApi(client), new ImmediateDispatcher());
    using var cancel = new CancellationTokenSource();
    var loading = vm.Preview.ExecuteAsync(new(30), cancel.Token);
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5)); cancel.Cancel();
    release.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new PlanCleanupResponse().ToByteArray()) });
    Check(!await loading && vm.Preview.Result is null);
    Check(!await vm.Execute.ExecuteAsync(new(Guid.NewGuid())));
});
await Test("三层存储策略保留 optional 继承、永久与显式零，限制后端安全整数", async () =>
{
    foreach (var scope in new[] { PolicyScope.Global, PolicyScope.Scene, PolicyScope.Chat })
    {
        var saved = new List<StoragePolicy>(); int resets = 0;
        using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
        {
            IMessage response;
            switch (request.RequestUri!.Segments.Last())
            {
                case "ListStoragePolicies": response = new ListStoragePoliciesResponse(); break;
                case "SetStoragePolicy":
                    saved.Add(SetStoragePolicyRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()).Policy);
                    response = new SetStoragePolicyResponse(); break;
                case "DeleteStoragePolicy":
                    var deleted = DeleteStoragePolicyRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
                    Check(deleted.Scope == scope && deleted.ChatId == (scope == PolicyScope.Chat ? 153 : 0)
                        && deleted.Scene == (scope == PolicyScope.Scene ? Scene.Group : Scene.Unspecified));
                    resets++; response = new DeleteStoragePolicyResponse { Deleted = true }; break;
                default: throw new Exception("意外请求");
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
        }));
        using var vm = new StoragePolicyViewModel(scope, Scene.Group, 153, new BridgeApi(client), new ImmediateDispatcher());
        Check(await vm.Load.ExecuteAsync(new()) && !vm.Load.Result!.HasKeepOriginalDays);
        Check(await vm.Save.ExecuteAsync(new(null, null, null, null, null)));
        Check(await vm.Save.ExecuteAsync(new(-1, 0, 0, (ulong)MessageIdentity.MaxValue, 0)));
        Check(saved[0].Scope == scope && !saved[0].HasAutoFetchMaxBytes && !saved[0].HasHotQuotaBytes);
        Check(saved[1].HasKeepOriginalDays && saved[1].KeepOriginalDays == -1 && saved[1].HasAutoFetchMaxBytes && saved[1].AutoFetchMaxBytes == 0);
        Check(saved[1].HasColdAfterDays && saved[1].ColdAfterDays == 0 && saved[1].ColdMinBytes == (ulong)MessageIdentity.MaxValue && saved[1].HasHotQuotaBytes);
        Check(!await vm.Save.ExecuteAsync(new(-2, null, null, null, null)));
        Check(!await vm.Save.ExecuteAsync(new(null, ulong.MaxValue, null, null, null)) && saved.Count == 2);
        Check(await vm.Reset.ExecuteAsync(new()) && resets == 1);
    }
});
await Test("存储策略加载固定作用域且保存中拒绝交叉操作", async () =>
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    int writes = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        if (request.RequestUri!.Segments.Last() == "ListStoragePolicies")
        {
            var list = new ListStoragePoliciesResponse();
            list.Policies.Add(new StoragePolicy { Scope = PolicyScope.Chat, ChatId = 999, KeepOriginalDays = 1 });
            list.Policies.Add(new StoragePolicy { Scope = PolicyScope.Chat, ChatId = 153, KeepOriginalDays = -1 });
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(list.ToByteArray()) });
        }
        Check(request.RequestUri.Segments.Last() == "SetStoragePolicy"); writes++; started.TrySetResult(); return release.Task;
    }));
    using var vm = new StoragePolicyViewModel(PolicyScope.Chat, Scene.Unspecified, 153, new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.Load.ExecuteAsync(new()) && vm.Load.Result!.KeepOriginalDays == -1);
    var saving = vm.Save.ExecuteAsync(new(30, null, null, null, null));
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    Check(!await vm.Reset.ExecuteAsync(new()) && writes == 1);
    release.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SetStoragePolicyResponse().ToByteArray()) });
    Check(await saving && vm.Load.Result!.KeepOriginalDays == -1);
});
await Test("相册分页失败沿用游标，重复媒体更新原位置并阻止游标循环", async () =>
{
    int calls = 0; var cursors = new List<string>();
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        var query = ListGroupAlbumMediaRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
        Check(query.GroupId == 123 && query.AlbumId == "album"); cursors.Add(query.Cursor); calls++;
        if (calls == 2) throw new IOException("offline");
        var page = new ListGroupAlbumMediaResponse { HasMore = true, NextCursor = calls == 1 ? "a" : calls == 3 ? "b" : "a", AlbumName = "相册" };
        page.Media.Add(new GroupAlbumMedia { Id = "one", Url = calls == 1 ? "https://fixture.test/old" : "https://fixture.test/new" });
        if (calls >= 3) page.Media.Add(new GroupAlbumMedia { Id = "two", IsVideo = true });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(page.ToByteArray()) };
    }));
    using var vm = new AlbumMediaViewModel(123, "album", new BridgeApi(client), new ImmediateDispatcher());
    Check(await vm.LoadMoreAsync() && vm.HasMore && vm.Items.Count == 1);
    Check(!await vm.LoadMoreAsync() && vm.HasMore && vm.Items.Count == 1);
    Check(await vm.LoadMoreAsync() && vm.Items.Count == 2 && vm.Items[0].Url == "https://fixture.test/new");
    Check(await vm.LoadMoreAsync() && !vm.HasMore && vm.PaginationError is not null);
    Check(!await vm.LoadMoreAsync() && calls == 4 && cursors.SequenceEqual(new[] { "", "a", "a", "b" }));
});
await Test("相册空终页正常结束，关闭后迟到页面不发布", async () =>
{
    using (var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new ByteArrayContent(new ListGroupAlbumMediaResponse().ToByteArray()) }))))
    {
        using var vm = new AlbumMediaViewModel(123, "empty", new BridgeApi(client), new ImmediateDispatcher());
        Check(await vm.LoadMoreAsync() && !vm.HasMore && vm.PaginationError is null && vm.Items.Count == 0);
    }
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
    using var delayed = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => { started.TrySetResult(); return release.Task; }));
    using var closed = new AlbumMediaViewModel(123, "late", new BridgeApi(delayed), new ImmediateDispatcher());
    var loading = closed.LoadMoreAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(5)); closed.Dispose();
    var page = new ListGroupAlbumMediaResponse(); page.Media.Add(new GroupAlbumMedia { Id = "late" });
    release.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(page.ToByteArray()) });
    Check(!await loading && closed.Items.Count == 0);
});
await Test("预览缓存并发去重、离线命中、损坏重取与账号目录隔离", async () =>
{
    string root = Path.Combine(Path.GetTempPath(), "preview-" + Guid.NewGuid().ToString("N"));
    string other = root + "-other";
    byte[] content = [1, 2, 3]; string sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(content)).ToLowerInvariant();
    int downloads = 0;
    async Task Download(Stream output, CancellationToken ct) { Interlocked.Increment(ref downloads); await output.WriteAsync(content, ct); }
    try
    {
        var cache = new PreviewCache(root, 16, 8);
        var results = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Task.Run(() => cache.GetAsync(sha, Download))));
        Check(downloads == 1 && results.Distinct().Count() == 1 && File.ReadAllBytes(results[0]).SequenceEqual(content));
        var reopened = new PreviewCache(root, 16, 8);
        Check(await reopened.GetAsync(sha, (_, _) => throw new IOException("offline")) == results[0]);
        await File.WriteAllBytesAsync(results[0], new byte[] { 9 });
        Check(await reopened.GetAsync(sha, Download) == results[0] && downloads == 2);
        var isolated = new PreviewCache(other, 16, 8);
        Check(await isolated.GetAsync(sha, Download) != results[0] && downloads == 3);
        try { await cache.GetAsync("../outside", Download); throw new Exception("应拒绝无效哈希"); } catch (ArgumentException) { }
    }
    finally { foreach (var directory in new[] { root, other }) if (Directory.Exists(directory)) { foreach (var file in Directory.GetFiles(directory)) File.Delete(file); Directory.Delete(directory); } }
});
await Test("预览缓存容量淘汰、哈希失败和取消不留下半成品", async () =>
{
    string root = Path.Combine(Path.GetTempPath(), "preview-" + Guid.NewGuid().ToString("N"));
    string Hash(byte[] data) => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data)).ToLowerInvariant();
    try
    {
        var cache = new PreviewCache(root, 4, 4); byte[] first = [1, 2, 3], second = [4, 5, 6];
        var previous = await cache.GetAsync(Hash(first), async (output, ct) => await output.WriteAsync(first, ct));
        var latest = await cache.GetAsync(Hash(second), async (output, ct) => await output.WriteAsync(second, ct));
        Check(!File.Exists(previous) && File.Exists(latest));
        try { await cache.GetAsync(Hash(first), async (output, ct) => await output.WriteAsync(second, ct)); throw new Exception("应哈希失败"); } catch (IOException) { }
        Check(!File.Exists(previous) && Directory.GetFiles(root, "*.tmp").Length == 0);
        using var source = new CancellationTokenSource();
        try
        {
            await cache.GetAsync(Hash(first), async (output, ct) => { await output.WriteAsync(first, ct); source.Cancel(); }, source.Token);
            throw new Exception("应取消");
        }
        catch (OperationCanceledException) { }
        Check(!File.Exists(previous) && Directory.GetFiles(root, "*.tmp").Length == 0 && File.Exists(latest));
    }
    finally { if (Directory.Exists(root)) { foreach (var file in Directory.GetFiles(root)) File.Delete(file); Directory.Delete(root); } }
});
await Test("预览下载不向签名地址附加设备令牌并限制声明大小", async () =>
{
    bool oversized = false;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(request =>
    {
        Check(request.Method == HttpMethod.Get && request.Headers.Authorization is null && request.RequestUri!.Host == "cdn.test");
        var body = new ByteArrayContent(new byte[] { 1, 2, 3 });
        if (oversized) body.Headers.ContentLength = 33 * 1024 * 1024;
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = body });
    })) { Token = "fixture-token" };
    using var output = new MemoryStream();
    await client.DownloadPreviewAsync("https://cdn.test/image?signature=fixture", output, CancellationToken.None);
    Check(output.ToArray().SequenceEqual(new byte[] { 1, 2, 3 }));
    oversized = true;
    try { await client.DownloadPreviewAsync("https://cdn.test/image", output, CancellationToken.None); throw new Exception("应拒绝超限预览"); } catch (IOException) { }
    Check(output.Length == 3);
});
await Test("缓存维护只清理托管文件，保留近期临时文件与其他账号内容", async () =>
{
    string root = Path.Combine(Path.GetTempPath(), "preview-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
        var cache = new PreviewCache(root + Path.DirectorySeparatorChar, 16, 8);
        string old = Path.Combine(root, Guid.NewGuid().ToString("N") + ".tmp");
        string recent = Path.Combine(root, Guid.NewGuid().ToString("N") + ".tmp");
        string unrelated = Path.Combine(root, "notes.blob");
        await File.WriteAllBytesAsync(old, new byte[] { 1 }); File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-2));
        await File.WriteAllBytesAsync(recent, new byte[] { 1 }); await File.WriteAllTextAsync(unrelated, "用户文件");
        byte[] bytes = [1, 2, 3]; string sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
        var path = await cache.GetAsync(sha, async (output, ct) => await output.WriteAsync(bytes, ct));
        Check(!File.Exists(old) && File.Exists(recent) && File.Exists(unrelated));
        var usage = await cache.GetUsageAsync(); Check(usage.Bytes == 3 && usage.Files == 1 && usage.TemporaryBytes == 1 && usage.Capacity == 16);
        var cleared = await cache.ClearAsync(); Check(cleared.RemovedBytes == 3 && cleared.RemovedFiles == 1 && cleared.SkippedFiles == 0);
        Check(!File.Exists(path) && File.Exists(recent) && File.Exists(unrelated));
        Check((await cache.GetUsageAsync()).Files == 0);
    }
    finally { foreach (var file in Directory.GetFiles(root)) File.Delete(file); Directory.Delete(root); }
});
await Test("缓存清理与下载串行，下载确认后清理不会遗留半成品", async () =>
{
    string root = Path.Combine(Path.GetTempPath(), "preview-" + Guid.NewGuid().ToString("N"));
    try
    {
        var cache = new PreviewCache(root, 16, 8);
        byte[] bytes = [1, 2, 3]; string sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var download = cache.GetAsync(sha, async (output, ct) => { await output.WriteAsync(bytes, ct); started.TrySetResult(); await release.Task; });
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var clear = cache.ClearAsync(); Check(!clear.IsCompleted);
        release.SetResult(); await download;
        var result = await clear;
        Check(result.RemovedFiles == 1 && Directory.GetFiles(root).Length == 0);
    }
    finally { if (Directory.Exists(root)) { foreach (var file in Directory.GetFiles(root)) File.Delete(file); Directory.Delete(root); } }
});
await Test("离线退出先持久化再清凭据，远端失败仍关闭本机会话", async () =>
{
    var steps = new List<string>();
    var result = await LogoutCoordinator.RunAsync(
        () => { steps.Add("persist"); return Task.CompletedTask; },
        () => steps.Add("clear"),
        _ => { steps.Add("remote"); throw new IOException("offline"); },
        () => { steps.Add("close"); return Task.CompletedTask; });
    Check(!result.RemoteRevoked && steps.SequenceEqual(new[] { "persist", "clear", "remote", "close" }));
    steps.Clear();
    try
    {
        await LogoutCoordinator.RunAsync(() => throw new IOException("disk full"), () => steps.Add("clear"),
            _ => { steps.Add("remote"); return Task.CompletedTask; }, () => { steps.Add("close"); return Task.CompletedTask; });
        throw new Exception("本地保存失败应停止退出");
    }
    catch (IOException) { }
    Check(steps.Count == 0);
    try
    {
        await LogoutCoordinator.RunAsync(() => Task.CompletedTask, () => throw new IOException("credential locked"),
            _ => { steps.Add("remote"); return Task.CompletedTask; }, () => { steps.Add("close"); return Task.CompletedTask; });
        throw new Exception("凭据未清除不能声称退出");
    }
    catch (IOException) { }
    Check(steps.Count == 0);
});
await Test("远端注销忽略取消时限时本机退出，正常确认保留成功状态", async () =>
{
    var remote = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); bool closed = false;
    var result = await LogoutCoordinator.RunAsync(() => Task.CompletedTask, () => { }, _ => remote.Task,
        () => { closed = true; return Task.CompletedTask; }, TimeSpan.FromMilliseconds(50)).WaitAsync(TimeSpan.FromSeconds(3));
    Check(closed && !result.RemoteRevoked);
    remote.SetException(new IOException("迟到错误"));
    result = await LogoutCoordinator.RunAsync(() => Task.CompletedTask, () => { }, _ => Task.CompletedTask, () => Task.CompletedTask);
    Check(result.RemoteRevoked);
});
await Test("连续实时同步只修复变化会话，联系人和发件箱更新不扫描全目录", async () =>
{
    using var store = new LocalStore(":memory:");
    var seed = new Difference { Pts = 1, IsFinal = true };
    seed.Dialogs.Add(new Dialog { ChatId = 153, DialogPts = 1, ChatPts = 1 });
    seed.Dialogs.Add(new Dialog { ChatId = 999, DialogPts = 1, ChatPts = 1 }); store.Apply(seed);
    store.ApplyChat(153, 1, [], []); store.ApplyChat(999, 1, [], []);
    var monitored = DispatchProxy.Create<ILocalStore, StoreReadProbe>();
    var probe = (StoreReadProbe)monitored; probe.Target = store;
    using var done = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    int readsAtSubscribe = 0, batches = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        IMessage response;
        switch (request.RequestUri!.Segments.Last())
        {
            case "GetState": response = new GetStateResponse { Pts = 1 }; break;
            case "GetDifference": response = new GetDifferenceResponse { Difference = new Difference { Pts = 1, IsFinal = true } }; break;
            case "GetChatDifferences":
                batches++; var query = GetChatDifferencesRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
                Check(query.Chats.Count == 1 && query.Chats[0].ChatId == 153 && query.Chats[0].ChatPts == 1);
                var batch = new GetChatDifferencesResponse(); batch.Chats.Add(new ChatDifferenceResult { ChatId = 153, ChatPts = 2, IsFinal = true }); response = batch; break;
            case "Subscribe":
                readsAtSubscribe = probe.DialogReads;
                var updates = new[] {
                    new SubscribeResponse { Peer = new PeerUpdate { Pts = 2, Peer = new Peer { PeerId = 2, Pts = 2 } } },
                    new SubscribeResponse { Outbox = new OutboxUpdate { Pts = 3, Entry = new OutboxEntry { ClientRandomId = 7, ChatId = 999, Pts = 3 } } },
                    new SubscribeResponse { Dialog = new DialogUpdate { Pts = 4, Dialog = new Dialog { ChatId = 153, DialogPts = 4, ChatPts = 2 } } },
                    new SubscribeResponse { Typing = new TypingUpdate { ChatId = 153 } } };
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(updates.SelectMany(u => Frame(0, u.ToByteArray())).Concat(Frame(2, "{}"u8.ToArray())).ToArray()) };
            default: throw new Exception("意外请求");
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    }));
    var sync = new SyncEngine(new BridgeApi(client), monitored); sync.Ephemeral += _ => done.Cancel();
    await sync.RunAsync(done.Token);
    Check(batches == 1 && probe.DialogReads == readsAtSubscribe && store.Cursor("chat:153") == 2 && store.Cursor("chat:999") == 1 && store.Cursor() == 4);
});
await Test("保存会话解析验证完整字段、地址与解密结果，忽略旧明文副本", () =>
{
    var saved = SavedSessionReader.Read("{\"Server\":\"https://bridge.test\",\"ProtectedToken\":\"encrypted-fixture\",\"Token\":\"legacy-ignored\"}",
        encrypted => { Check(encrypted == "encrypted-fixture"); return "decrypted-fixture"; });
    Check(saved.Token == "decrypted-fixture" && saved.Server == "https://bridge.test");
    foreach (string json in new[] { "null", "{}", "{", "{\"Server\":\"https://bridge.test\"}",
        "{\"Server\":\"file:///tmp\",\"ProtectedToken\":\"fixture\"}", new string(' ', 65537) })
    {
        bool rejected = false;
        try { SavedSessionReader.Read(json, _ => "fixture"); }
        catch (Exception error) when (error is ArgumentException or InvalidDataException or System.Text.Json.JsonException) { rejected = true; }
        Check(rejected);
    }
    try { SavedSessionReader.Read("{\"Server\":\"https://bridge.test\",\"ProtectedToken\":\"fixture\"}", _ => " "); throw new Exception("空凭据应拒绝"); }
    catch (InvalidDataException) { }
    return Task.CompletedTask;
});
await Test("发送校验对齐后端文字、段数、媒体组合与文件名规则", () =>
{
    string sha = new('a', 64);
    SendMessageRequest Message(params OutgoingSegment[] segments)
    { var request = new SendMessageRequest { ChatId = 153, ClientRandomId = 77 }; request.Segments.Add(segments); return request; }
    var rich = Message(new() { Text = "文字" }, new() { MentionUserId = 123 }, new() { FaceId = "123" }, new() { Image = new() { Sha256 = sha } });
    rich.ReplyToSeq = 9; OutgoingValidation.Validate(rich);
    OutgoingValidation.Validate(Message(new OutgoingSegment { Text = string.Concat(Enumerable.Repeat("😀", 2500)) }));
    OutgoingValidation.Validate(Message(Enumerable.Range(0, 50).Select(_ => new OutgoingSegment { FaceId = "1" }).ToArray()));
    OutgoingValidation.Validate(Message(new OutgoingSegment { File = new() { Sha256 = sha, Name = "报告.pdf" } }));
    var invalid = new List<SendMessageRequest>
    {
        Message(new OutgoingSegment()), Message(new OutgoingSegment { Text = "" }),
        Message(new OutgoingSegment { Text = new string('x', 5000) }, new OutgoingSegment { Text = "x" }),
        Message(Enumerable.Range(0, 51).Select(_ => new OutgoingSegment { FaceId = "1" }).ToArray()),
        Message(new OutgoingSegment { FaceId = "１２" }), Message(new OutgoingSegment { FaceId = "1234567" }),
        Message(new OutgoingSegment { MentionUserId = long.MaxValue }),
        Message(new OutgoingSegment { Image = new() { Sha256 = sha.ToUpperInvariant() } }),
        Message(new OutgoingSegment { File = new() { Sha256 = sha, Name = "../file" } }),
        Message(new OutgoingSegment { File = new() { Sha256 = sha, Name = " " } }),
        Message(new OutgoingSegment { Video = new() { Sha256 = sha } }, new OutgoingSegment { Text = "附言" }),
        Message(new OutgoingSegment { Forward = new() })
    };
    foreach (var segment in new[] { new OutgoingSegment { Record = new() { Sha256 = sha } }, new OutgoingSegment { Video = new() { Sha256 = sha } }, new OutgoingSegment { File = new() { Sha256 = sha, Name = "file" } } })
    { var request = Message(segment); request.ReplyToSeq = 1; invalid.Add(request); }
    foreach (var request in invalid)
    {
        bool rejected = false; try { OutgoingValidation.Validate(request); } catch (ArgumentException) { rejected = true; }
        Check(rejected);
    }
    return Task.CompletedTask;
});
await Test("非法发送内容在落库和网络之前拒绝", async () =>
{
    int calls = 0;
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(_ => { calls++; throw new Exception("不应请求网络"); }));
    var request = new SendMessageRequest { ChatId = 153, ClientRandomId = 77, ReplyToSeq = 1 };
    request.Segments.Add(new OutgoingSegment { File = new() { Sha256 = new string('a', 64), Name = "file" } });
    try { await session.QueueMessageAsync(request); throw new Exception("应拒绝入库"); } catch (ArgumentException) { }
    try { await session.SendMessageAsync(request); throw new Exception("应拒绝发送"); } catch (ArgumentException) { }
    Check(calls == 0 && session.LegacyStore.Read("pending", SendMessageRequest.Parser).Count == 0);
});
await Test("转发去重、排序、限制和请求快照", () =>
{
    var source = new ForwardMessagesRequest { FromChatId = 153, Bundle = true };
    source.Seqs.AddRange(new long[] { 3, 1, 3 }); source.ToChatIds.AddRange(new long[] { 8, 8, 9 });
    var copy = ForwardValidation.Normalize(source); source.Seqs.Clear();
    Check(copy.Bundle && copy.Seqs.SequenceEqual(new long[] { 1, 3 }) && copy.ToChatIds.SequenceEqual(new long[] { 8, 9 }));
    foreach (var invalid in new[] { new ForwardMessagesRequest(), copy.Clone(), copy.Clone(), copy.Clone() }.Select((r, i) =>
    {
        if (i == 1) r.FromChatId = long.MaxValue;
        if (i == 2) r.Seqs.AddRange(Enumerable.Range(1, 101).Select(x => (long)x));
        if (i == 3) r.ToChatIds.AddRange(Enumerable.Range(1, 21).Select(x => (long)x));
        return r;
    }))
    { bool rejected = false; try { ForwardValidation.Normalize(invalid); } catch (ArgumentException) { rejected = true; } Check(rejected); }
    return Task.CompletedTask;
});
await Test("转发协议路径与确认落库，原生空响应也成功且不推进游标", async () =>
{
    int calls = 0;
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(async request =>
        {
            Check(request.RequestUri!.AbsolutePath.EndsWith("/MessageService/ForwardMessages") || request.RequestUri.AbsolutePath.EndsWith(".MessageService/ForwardMessages"));
            var parsed = ForwardMessagesRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
            Check(parsed.Bundle && parsed.Seqs.SequenceEqual(new long[] { 1, 2 }) && parsed.ToChatIds.Single() == 153);
            var response = new ForwardMessagesResponse();
            if (++calls == 1) response.Entries.Add(new OutboxEntry { ChatId = 153, ClientRandomId = 77, Pts = 40, State = OutboxState.Pending });
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
        }));
    var input = new ForwardMessagesRequest { FromChatId = 9, Bundle = true };
    input.Seqs.AddRange(new long[] { 2, 1, 2 }); input.ToChatIds.Add(153);
    await session.ForwardMessagesAsync(input);
    Check(session.LegacyStore.Read("outbox", OutboxEntry.Parser).Single().ClientRandomId == 77);
    Check((await session.ForwardMessagesAsync(input)).Entries.Count == 0);
    Check(calls == 2 && session.LegacyStore.Cursor() == 0);
});
await Test("转发操作单飞且超时不自动重发并提示结果不确定", async () =>
{
    int calls = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    await using var vm = new ForwardMessagesViewModel(async (request, ct) =>
    { calls++; started.SetResult(); await release.Task; throw new IOException("fixture timeout"); }, new ImmediateDispatcher());
    var input = new ForwardMessagesRequest { FromChatId = 1 }; input.Seqs.Add(1); input.ToChatIds.Add(153);
    var sending = vm.SendAsync(input); await started.Task;
    Check(!await vm.SendAsync(input)); release.SetResult();
    Check(!await sending && vm.Send.OutcomeUncertain && calls == 1);
});
await Test("活跃会话串行且合并旧意图，失焦清空可重复续期", async () =>
{
    var calls = new List<long>(); var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var active = new ActiveChatCoordinator(async (chat, ct) =>
    { calls.Add(chat); if (calls.Count == 1) { started.SetResult(); await release.Task; } });
    var first = active.SetAsync(153); await started.Task;
    var old = active.SetAsync(8); var clear = active.SetAsync(0);
    Check(calls.SequenceEqual(new long[] { 153 })); release.SetResult();
    await Task.WhenAll(first, old, clear);
    Check(calls.SequenceEqual(new long[] { 153, 0 }));
    await active.SetAsync(153); await active.SetAsync(153);
    Check(calls.SequenceEqual(new long[] { 153, 0, 153, 153 }));
});
await Test("会话关闭等待活跃请求且取消排队意图，不释放仍使用的传输", async () =>
{
    int calls = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    { calls++; started.SetResult(); await release.Task; return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SetActiveChatResponse().ToByteArray()) }; });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var first = session.SetActiveChatAsync(153); await started.Task;
    var queued = session.SetActiveChatAsync(8);
    var closing = session.DisposeAsync().AsTask();
    try { await queued.WaitAsync(TimeSpan.FromSeconds(5)); throw new Exception("排队请求应取消"); } catch (OperationCanceledException) { }
    Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); try { await first; } catch (OperationCanceledException) { }
    await closing; Check(calls == 1 && handler.IsDisposed);
    try { await session.SetActiveChatAsync(0); throw new Exception("关闭后应拒绝请求"); } catch (ObjectDisposedException) { }
});
await Test("回应确认按版本合并且不推进游标，不匹配确认不污染缓存", async () =>
{
    long responseChat = 153; int version = 2;
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(async request =>
        {
            Check(request.RequestUri!.AbsolutePath.EndsWith(".MessageService/React"));
            var parsed = ReactRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
            Check(parsed.ChatId == 153 && parsed.Seq == 9 && parsed.EmojiId == "128077" && parsed.Add);
            var message = new Message { ChatId = responseChat, Seq = 9, Version = version, Text = "response" };
            message.Reactions.Add(new Reaction { EmojiId = "128077", Count = 1, Me = true });
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new ReactResponse { Message = message }.ToByteArray()) };
        }));
    var input = new ReactRequest { ChatId = 153, Seq = 9, EmojiId = "128077", Add = true };
    await session.ReactAsync(input);
    Check(session.LegacyStore.Messages(153).Single().Reactions.Single().Me);
    session.LegacyStore.MergeHistory(153, new[] { new Message { ChatId = 153, Seq = 9, Version = 3, State = MessageState.Recalled } }, Array.Empty<ChatEvent>());
    await session.ReactAsync(input);
    Check(session.LegacyStore.Messages(153).Single().State == MessageState.Recalled);
    responseChat = 8;
    try { await session.ReactAsync(input); throw new Exception("应拒绝错误消息"); } catch (IOException) { }
    Check(session.LegacyStore.Messages(8).Count == 0 && session.LegacyStore.Cursor("chat:153") == 0 && session.LegacyStore.Cursor() == 0);
});
await Test("同一消息撤回与回应互斥，失败释放操作锁且非法输入不请求网络", async () =>
{
    int calls = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(async request =>
        {
            if (++calls == 1) { started.SetResult(); await release.Task; throw new IOException("fixture failure"); }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new RecallMessageResponse().ToByteArray()) };
        }));
    var first = session.RecallMessageAsync(new() { ChatId = 153, Seq = 9 }); await started.Task;
    try { await session.ReactAsync(new() { ChatId = 153, Seq = 9, EmojiId = "1" }); throw new Exception("应拒绝重复操作"); } catch (InvalidOperationException) { }
    release.SetResult(); try { await first; throw new Exception("应失败"); } catch (IOException) { }
    await session.RecallMessageAsync(new() { ChatId = 153, Seq = 9 });
    foreach (string invalid in new[] { "", "１２", "12345678901" })
    { try { await session.ReactAsync(new() { ChatId = 153, Seq = 9, EmojiId = invalid }); throw new Exception("应拒绝非法表情"); } catch (ArgumentException) { } }
    try { await session.RecallMessageAsync(new() { ChatId = long.MaxValue, Seq = 9 }); throw new Exception("应拒绝溢出 ID"); } catch (ArgumentException) { }
    Check(calls == 2);
});
await Test("空搜索终止分页，重置重新请求，循环游标不能无限翻页", async () =>
{
    int calls = 0;
    var empty = new MessageSearchPager((_, _) => { calls++; return Task.FromResult(new SearchMessagesResponse()); });
    empty.Reset("空结果"); Check(await empty.LoadAsync(default)); Check(!await empty.LoadAsync(default) && calls == 1);
    empty.Reset("重新查询"); Check(await empty.LoadAsync(default) && calls == 2);
    int pages = 0;
    var cyclic = new MessageSearchPager((_, _) =>
    {
        var response = new SearchMessagesResponse { Next = new SearchCursor { ChatId = 153, Seq = ++pages % 2 == 1 ? 9 : 8, Time = 1 } };
        response.Messages.Add(new Message { ChatId = 153, Seq = pages }); return Task.FromResult(response);
    });
    cyclic.Reset("循环"); await cyclic.LoadAsync(default); await cyclic.LoadAsync(default); await cyclic.LoadAsync(default);
    Check(cyclic.Next is null && !await cyclic.LoadAsync(default) && pages == 3);
});
await Test("搜索结果持有独立快照，取消首页仍可重试", async () =>
{
    var response = new SearchMessagesResponse(); response.Messages.Add(new Message { ChatId = 153, Seq = 1, Text = "原文" });
    int calls = 0;
    var pager = new MessageSearchPager((_, ct) => { calls++; ct.ThrowIfCancellationRequested(); return Task.FromResult(response); });
    pager.Reset("关键词"); using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    try { await pager.LoadAsync(cancelled.Token); throw new Exception("应取消"); } catch (OperationCanceledException) { }
    Check(await pager.LoadAsync(default)); response.Messages[0].Text = "被外部修改";
    Check(pager.Results.Single().Text == "原文" && calls == 2);
});
await Test("AI 语音要求当前群角色，发送参数归一且失败不自动重发", async () =>
{
    int sends = 0;
    await using var vm = new AiVoiceViewModel(153, (request, ct) =>
    {
        Check(request.ChatId == 153); var response = new ListAiVoicesResponse();
        var category = new AiVoiceCategory { Name = "测试角色" }; category.Voices.Add(new AiVoice { Id = "voice-a", Name = "测试" });
        response.Categories.Add(category); return Task.FromResult(response);
    }, (request, ct) =>
    {
        sends++; Check(request.ChatId == 153 && request.VoiceId == "voice-a" && request.Text == "朗读内容");
        throw new IOException("fixture timeout");
    }, new ImmediateDispatcher());
    try { await vm.SendAsync("voice-a", "内容"); throw new Exception("未加载不能发送"); } catch (ArgumentException) { }
    Check(await vm.LoadAsync());
    try { await vm.SendAsync("unknown", "内容"); throw new Exception("未知角色不能发送"); } catch (ArgumentException) { }
    try { await vm.SendAsync("voice-a", "  "); throw new Exception("空内容不能发送"); } catch (ArgumentException) { }
    Check(!await vm.SendAsync("voice-a", "  朗读内容  ") && vm.Send.OutcomeUncertain && sends == 1);
});
await Test("语音请求协议与同群发送互斥，转写空结果有效且不产生本地消息", async () =>
{
    int sends = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(async request =>
        {
            string path = request.RequestUri!.AbsolutePath;
            byte[] bytes = await request.Content!.ReadAsByteArrayAsync();
            if (path.EndsWith("/SendAiVoice"))
            {
                var input = SendAiVoiceRequest.Parser.ParseFrom(bytes); Check(input.ChatId == 153 && input.Text == "内容" && input.VoiceId == "a");
                sends++; started.TrySetResult(); await release.Task;
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SendAiVoiceResponse().ToByteArray()) };
            }
            Check(path.EndsWith("/TranscribeVoice"));
            var transcription = TranscribeVoiceRequest.Parser.ParseFrom(bytes); Check(transcription.ChatId == 153 && transcription.Seq == 9);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new TranscribeVoiceResponse().ToByteArray()) };
        }));
    var input = new SendAiVoiceRequest { ChatId = 153, VoiceId = "a", Text = " 内容 " };
    var sending = session.SendAiVoiceAsync(input); input.Text = "调用者已改动"; await started.Task;
    try { await session.SendAiVoiceAsync(new() { ChatId = 153, VoiceId = "a", Text = "内容" }); throw new Exception("应拒绝重复发送"); } catch (InvalidOperationException) { }
    release.SetResult(); await sending;
    var result = await session.TranscribeVoiceAsync(new() { ChatId = 153, Seq = 9 });
    Check(result.Text == "" && sends == 1 && session.LegacyStore.Messages(153).Count == 0 && session.LegacyStore.Cursor() == 0);
});
await Test("上传提前 EOF 和读取期间文件变化不能误报成功", async () =>
{
    foreach (bool truncate in new[] { false, true })
    {
        int requests = 0;
        using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(_ => { requests++; throw new Exception("不应上传坏块"); }));
        using var source = new InterruptedUploadStream(truncate);
        bool rejected = false;
        try { await client.UploadAsync("/upload/1", source, 0, default); } catch (IOException) { rejected = true; }
        Check(rejected && requests == 0 && source.CanRead);
    }
});
await Test("上传短读持续至完整长度，取消完成偏移也不能返回成功", async () =>
{
    int requests = 0; long confirmed = 0;
    using var client = new ConnectClient(new Uri("https://bridge.test"), new Handler(async request =>
    {
        Check(long.Parse(request.Headers.GetValues("Upload-Offset").Single()) == confirmed);
        confirmed += (await request.Content!.ReadAsByteArrayAsync()).Length; requests++;
        var response = new HttpResponseMessage(HttpStatusCode.NoContent); response.Headers.Add("Upload-Offset", confirmed.ToString()); return response;
    }));
    using var source = new FragmentedStream(new byte[11]); await client.UploadAsync("/upload/1", source, 0, default);
    Check(confirmed == 11 && requests == 6 && source.CanRead);
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    try { await client.UploadAsync("/upload/1", source, 11, cancelled.Token); throw new Exception("应取消"); } catch (OperationCanceledException) { }
});
await Test("准备上传期间源文件缩短时不接受秒传确认", async () =>
{
    using var source = new MemoryStream(new byte[10]);
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(_ =>
        {
            source.SetLength(2);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new PrepareUploadResponse { Exists = true }.ToByteArray()) });
        }));
    bool rejected = false;
    try { await session.UploadMediaAsync(source, "fixture.bin", "application/octet-stream"); } catch (IOException) { rejected = true; }
    Check(rejected && source.CanRead);
});
await Test("输入状态按会话节流且请求目标稳定，已读只确认不修改同步游标", async () =>
{
    var chats = new List<long>(); int reads = 0;
    await using var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(),
        handler: new Handler(async request =>
        {
            var bytes = await request.Content!.ReadAsByteArrayAsync();
            if (request.RequestUri!.AbsolutePath.EndsWith("/SetTyping"))
            {
                chats.Add(SetTypingRequest.Parser.ParseFrom(bytes).ChatId);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new SetTypingResponse { Sent = true }.ToByteArray()) };
            }
            Check(request.RequestUri.AbsolutePath.EndsWith("/MarkRead"));
            var read = MarkReadRequest.Parser.ParseFrom(bytes); Check(read.ChatId == 153 && read.MaxSeq == 9); reads++;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new MarkReadResponse { Changed = true }.ToByteArray()) };
        }));
    Check((await session.SetTypingAsync(153)).Sent);
    Check(!(await session.SetTypingAsync(153)).Sent);
    Check((await session.SetTypingAsync(8)).Sent && chats.SequenceEqual(new long[] { 153, 8 }));
    Check(await session.ReadReceipts.SubmitAsync(153, 9, 0, default));
    Check(!await session.ReadReceipts.SubmitAsync(153, 8, 0, default));
    Check(reads == 1 && session.LegacyStore.Cursor() == 0 && session.LegacyStore.Cursor("chat:153") == 0);
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    try { await session.SetTypingAsync(153, cancelled.Token); throw new Exception("取消不能被节流吞掉"); } catch (OperationCanceledException) { }
});
await Test("设备撤销不作用于当前设备，迟到列表不能恢复已撤销设备", async () =>
{
    var old = new TaskCompletionSource<ListDevicesResponse>(); int loads = 0, revokes = 0;
    ListDevicesResponse Snapshot()
    {
        var response = new ListDevicesResponse(); response.Devices.Add(new Device { Id = 1, Current = true, Name = "本机" });
        response.Devices.Add(new Device { Id = 2, Name = "其他设备" }); return response;
    }
    await using var vm = new DevicesViewModel((_, _) => ++loads == 1 ? Task.FromResult(Snapshot()) : old.Task,
        (request, _) => { revokes++; Check(request.DeviceId == 2); return Task.FromResult(new RevokeDeviceResponse { Revoked = false }); }, new ImmediateDispatcher());
    Check(await vm.LoadAsync());
    Check(!await vm.RevokeAsync(1) && !await vm.RevokeAsync(99) && revokes == 0);
    var refresh = vm.LoadAsync(); Check(await vm.RevokeAsync(2));
    Check(vm.Items.Count == 1); old.SetResult(Snapshot()); Check(await refresh && vm.Items.Count == 1);
    var item = vm.Items.Single(); item.Name = "外部修改"; Check(vm.Items.Single().Name == "本机");
    Check(!await vm.RevokeAsync(2) && revokes == 1);
});
await Test("设备撤销网络失败保留列表，已关闭页面不发布迟到列表", async () =>
{
    var pending = new TaskCompletionSource<ListDevicesResponse>(); int updates = 0;
    var response = new ListDevicesResponse(); response.Devices.Add(new Device { Id = 2, Name = "fixture" });
    int loads = 0;
    var vm = new DevicesViewModel((_, _) => ++loads == 1 ? Task.FromResult(response) : pending.Task,
        (_, _) => throw new IOException("fixture timeout"), new ImmediateDispatcher());
    vm.PropertyChanged += (_, _) => updates++;
    Check(await vm.LoadAsync()); Check(!await vm.RevokeAsync(2) && vm.Revoke.OutcomeUncertain && vm.Items.Count == 1);
    int before = updates; var loading = vm.LoadAsync(); vm.Dispose(); pending.SetResult(new ListDevicesResponse());
    Check(!await loading && updates == before && vm.Items.Count == 1); await vm.DisposeAsync();
});
await Test("关闭期间一个请求失败仍等待其他请求收尾，再释放全部资源", async () =>
{
    var firstStarted = new TaskCompletionSource(); var secondStarted = new TaskCompletionSource();
    var fail = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        if (request.RequestUri!.AbsolutePath.EndsWith("/RecallMessage"))
        { firstStarted.SetResult(); await fail.Task; throw new IOException("fixture failure during shutdown"); }
        secondStarted.SetResult(); await release.Task;
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new ListDevicesResponse().ToByteArray()) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var first = session.RecallMessageAsync(new() { ChatId = 153, Seq = 9 });
    var second = session.ListDevicesAsync(new()); await Task.WhenAll(firstStarted.Task, secondStarted.Task);
    var closing = session.DisposeAsync().AsTask();
    try { await session.SetActiveChatAsync(0); throw new Exception("关闭时应拒绝新请求"); } catch (ObjectDisposedException) { }
    fail.SetResult(); try { await first; } catch (IOException) { }
    Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); try { await second; } catch (OperationCanceledException) { }
    try { await closing; } catch (IOException) { }
    Check(handler.IsDisposed);
    try { await session.Repository.GetPeersAsync(); throw new Exception("仓储必须关闭"); } catch (ObjectDisposedException) { }
});
await Test("历史窗口查询计划使用主键与序号范围，不扫描整个会话", () =>
{
    using var db = new SqliteConnection("Data Source=:memory:"); db.Open();
    using var schema = db.CreateCommand();
    schema.CommandText = "CREATE TABLE records(kind TEXT NOT NULL,key TEXT NOT NULL,chat INTEGER NOT NULL,seq INTEGER NOT NULL,version INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(kind,key)); CREATE INDEX records_chat_seq ON records(kind,chat,seq);";
    schema.ExecuteNonQuery();
    foreach (bool includeNewer in new[] { false, true })
    {
        using var plan = db.CreateCommand(); plan.CommandText = "EXPLAIN QUERY PLAN " + LocalStore.WindowQuery(includeNewer);
        plan.Parameters.AddWithValue("$kind", "message"); plan.Parameters.AddWithValue("$chat", 153);
        plan.Parameters.AddWithValue("$keys", "[\"153:999\"]"); if (includeNewer) plan.Parameters.AddWithValue("$boundary", 1000);
        using var reader = plan.ExecuteReader(); var lines = new List<string>(); while (reader.Read()) lines.Add(reader.GetString(3));
        Check(lines.Any(l => l.Contains("kind=? AND key=?")));
        Check(!lines.Any(l => l.StartsWith("SCAN r") || l.StartsWith("SCAN records")));
        if (includeNewer) Check(lines.Any(l => l.Contains("kind=? AND chat=? AND seq>?")));
    }
    return Task.CompletedTask;
});
await Test("拆分窗口查询保留排序与去重，不混入其他会话或历史孤岛", () =>
{
    using var store = new LocalStore(":memory:");
    store.MergeHistory(153, Enumerable.Range(1, 20000).Select(i => new Message { ChatId = 153, Seq = i, Version = 1 }), Array.Empty<ChatEvent>());
    store.MergeHistory(154, new[] { new Message { ChatId = 154, Seq = 20001, Version = 1 } }, Array.Empty<ChatEvent>());
    var keys = new[] { "153:5", "153:5", "153:19999", "154:20001", "153:99999" };
    var result = store.ReadWindow("message", Message.Parser, 153, keys, 19998);
    Check(result.Select(m => m.Seq).SequenceEqual(new long[] { 5, 19999, 20000 }));
    Check(store.ReadWindow("message", Message.Parser, 153, keys, null).Select(m => m.Seq).SequenceEqual(new long[] { 5, 19999 }));
    Check(store.ReadWindow("message", Message.Parser, 153, Array.Empty<string>(), null).Count == 0);
    return Task.CompletedTask;
});
await Test("v1 发件箱迁移保留已发送幂等记录，窗口只读取活动条目且迟到版本不复活", () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open(); using var create = db.CreateCommand();
            create.CommandText = "CREATE TABLE records(kind TEXT NOT NULL,key TEXT NOT NULL,chat INTEGER NOT NULL DEFAULT 0,seq INTEGER NOT NULL DEFAULT 0,version INTEGER NOT NULL DEFAULT 0,data BLOB NOT NULL,PRIMARY KEY(kind,key)); CREATE INDEX records_chat_seq ON records(kind,chat,seq); CREATE TABLE cursors(key TEXT PRIMARY KEY,value INTEGER NOT NULL); INSERT INTO cursors VALUES('global',99); PRAGMA user_version=1;"; create.ExecuteNonQuery();
            using var insert = db.CreateCommand(); insert.CommandText = "INSERT INTO records VALUES('outbox',$key,153,0,9,$data)";
            var key = insert.Parameters.AddWithValue("$key", ""); var data = insert.Parameters.Add("$data", SqliteType.Blob);
            foreach (var entry in new[] { new OutboxEntry { ClientRandomId = 1, ChatId = 153, Pts = 9, State = OutboxState.Sent }, new OutboxEntry { ClientRandomId = 2, ChatId = 153, Pts = 9, State = OutboxState.Failed } })
            { key.Value = entry.ClientRandomId.ToString(); data.Value = entry.ToByteArray(); insert.ExecuteNonQuery(); }
        }
        using (var store = new LocalStore(path))
        {
            var query = new TimelineQuery(153, [], [], null, null, true);
            Check(store.Cursor() == 99 && store.Read("outbox", OutboxEntry.Parser).Count == 2);
            Check(store.ReadTimeline(query).Outbox.Single().ClientRandomId == 2);
            store.AcceptPending(new OutboxEntry { ClientRandomId = 2, ChatId = 153, Pts = 10, State = OutboxState.Sent });
            store.AcceptPending(new OutboxEntry { ClientRandomId = 2, ChatId = 153, Pts = 9, State = OutboxState.Failed });
            Check(store.ReadTimeline(query).Outbox.Count == 0 && store.Cursor() == 99);
        }
        using (var reopened = new LocalStore(path)) Check(reopened.Read("outbox", OutboxEntry.Parser).Count == 2);
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open(); using var plan = db.CreateCommand(); plan.CommandText = "EXPLAIN QUERY PLAN " + LocalStore.ActiveOutboxQuery;
            plan.Parameters.AddWithValue("$chat", 153); using var reader = plan.ExecuteReader(); var lines = new List<string>();
            while (reader.Read()) lines.Add(reader.GetString(3));
            Check(lines.Any(l => l.Contains("records_active_outbox (chat=?)")));
        }
    }
    finally { SqliteConnection.ClearAllPools(); File.Delete(path); File.Delete(path + "-wal"); File.Delete(path + "-shm"); }
    return Task.CompletedTask;
});
await Test("发件箱索引迁移失败完整回滚，不留下半升级格式", () =>
{
    var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".sqlite");
    try
    {
        using (var db = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            db.Open(); using var create = db.CreateCommand();
            create.CommandText = "CREATE TABLE records(kind TEXT NOT NULL,key TEXT NOT NULL,chat INTEGER NOT NULL DEFAULT 0,seq INTEGER NOT NULL DEFAULT 0,version INTEGER NOT NULL DEFAULT 0,data BLOB NOT NULL,PRIMARY KEY(kind,key)); CREATE INDEX records_chat_seq ON records(kind,chat,seq); CREATE TABLE cursors(key TEXT PRIMARY KEY,value INTEGER NOT NULL); INSERT INTO records VALUES('outbox','1',153,0,1,X'FF'); PRAGMA user_version=1;"; create.ExecuteNonQuery();
        }
        bool failed = false; try { using var store = new LocalStore(path); } catch (InvalidProtocolBufferException) { failed = true; } Check(failed);
        using var inspect = new SqliteConnection($"Data Source={path};Pooling=False"); inspect.Open(); using var cmd = inspect.CreateCommand();
        cmd.CommandText = "PRAGMA user_version"; Check(Convert.ToInt32(cmd.ExecuteScalar()) == 1);
        cmd.CommandText = "SELECT count(*) FROM pragma_table_info('records') WHERE name='active_outbox'"; Check(Convert.ToInt32(cmd.ExecuteScalar()) == 0);
        cmd.CommandText = "SELECT hex(data) FROM records WHERE key='1'"; Check((string?)cmd.ExecuteScalar() == "FF");
    }
    finally { SqliteConnection.ClearAllPools(); File.Delete(path); File.Delete(path + "-wal"); File.Delete(path + "-shm"); }
    return Task.CompletedTask;
});
await Test("麦克风授权迟到时取消不复活录音，释放后可重新开始", async () =>
{
    var permission = new TaskCompletionSource(); var native = new TestVoiceRecorder { StartWait = permission.Task };
    await using var recorder = new VoiceRecordingSession(native);
    var starting = recorder.StartAsync(); Check(recorder.State == VoiceRecordingState.Starting);
    var cancelled = recorder.CancelAsync(); permission.SetResult(); await Task.WhenAll(starting, cancelled);
    Check(recorder.State == VoiceRecordingState.Idle && recorder.Recording is null && !native.Active);
    native.StartWait = Task.CompletedTask; await recorder.StartAsync(); Check(recorder.State == VoiceRecordingState.Recording);
    await recorder.CancelAsync(); Check(!native.Active);
});
await Test("过短录音拒绝发送，可重录；关闭清除已完成内容并只释放一次", async () =>
{
    var native = new TestVoiceRecorder { Duration = TimeSpan.FromMilliseconds(500) };
    var recorder = new VoiceRecordingSession(native);
    await recorder.StartAsync(); await recorder.FinishAsync();
    Check(recorder.State == VoiceRecordingState.Failed && recorder.Recording is null && !native.Active);
    native.Duration = TimeSpan.FromSeconds(2); await recorder.StartAsync(); await recorder.FinishAsync();
    Check(recorder.State == VoiceRecordingState.Ready && recorder.Recording!.Duration.TotalSeconds == 2);
    await recorder.DisposeAsync(); await recorder.DisposeAsync();
    Check(recorder.State == VoiceRecordingState.Disposed && recorder.Recording is null && native.Disposals == 1);
    await recorder.StartAsync(); Check(!native.Active && recorder.State == VoiceRecordingState.Disposed);
});
await Test("录音上限自动停止仅生成待确认内容，取消停止期间不保留录音", async () =>
{
    var clock = new RecordingClock(); var native = new TestVoiceRecorder();
    await using var recorder = new VoiceRecordingSession(native, clock);
    var ready = new TaskCompletionSource(); recorder.PropertyChanged += (_, _) => { if (recorder.State == VoiceRecordingState.Ready) ready.TrySetResult(); };
    await recorder.StartAsync(); Check(clock.Due == TimeSpan.FromSeconds(60)); clock.Fire!();
    await ready.Task.WaitAsync(TimeSpan.FromSeconds(5)); Check(native.Finishes == 1 && !native.Active && recorder.Recording is not null);
    var finish = new TaskCompletionSource(); native.FinishWait = finish.Task; await recorder.StartAsync();
    var stopping = recorder.FinishAsync(); var cancelling = recorder.CancelAsync(); finish.SetResult();
    await Task.WhenAll(stopping, cancelling); Check(recorder.State == VoiceRecordingState.Idle && recorder.Recording is null);
});
await Test("录音上传失败保留音频，发送超时重试复用媒体和幂等 ID", async () =>
{
    int uploads = 0, sends = 0; var voice = new RecordedVoice(new byte[] { 1, 2, 3 }, TimeSpan.FromSeconds(2.2));
    await using var vm = new VoiceMessageSendViewModel(153, 77, voice, async (stream, name, mime, ct) =>
    {
        uploads++; using var bytes = new MemoryStream(); await stream.CopyToAsync(bytes, ct);
        Check(bytes.ToArray().SequenceEqual(new byte[] { 1, 2, 3 }));
        if (uploads == 1) throw new IOException("fixture upload failure");
        return new OutgoingMedia { Sha256 = new string('a', 64) };
    }, (request, ct) =>
    {
        sends++; Check(request.ChatId == 153 && request.ClientRandomId == 77 && request.ReplyToSeq == 0);
        Check(request.Segments.Single().Record.DurationSec == 3 && request.Segments.Single().Record.Sha256 == new string('a', 64));
        if (sends == 1) { request.Segments.Clear(); throw new IOException("fixture lost acknowledgment"); }
        return Task.FromResult(new SendMessageResponse { Entry = new OutboxEntry { ChatId = 153, ClientRandomId = 77, State = OutboxState.Pending } });
    }, new ImmediateDispatcher());
    voice.Audio[0] = 9;
    Check(!await vm.SendAsync() && uploads == 1 && sends == 0);
    Check(!await vm.SendAsync() && uploads == 2 && sends == 1);
    Check(await vm.SendAsync() && uploads == 2 && sends == 2);
    Check(await vm.SendAsync() && sends == 2);
});
await Test("语音发送取消后迟到确认仍避免重发，重复点击不并行发送", async () =>
{
    int sends = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    await using var vm = new VoiceMessageSendViewModel(153, 88, new RecordedVoice(new byte[] { 1 }, TimeSpan.FromSeconds(2)),
        (_, _, _, _) => Task.FromResult(new OutgoingMedia { Sha256 = new string('b', 64) }),
        async (_, _) => { sends++; started.SetResult(); await release.Task; return new SendMessageResponse { Entry = new OutboxEntry { ChatId = 153, ClientRandomId = 88 } }; }, new ImmediateDispatcher());
    using var cancelled = new CancellationTokenSource(); var sending = vm.SendAsync(cancelled.Token); await started.Task;
    Check(!await vm.SendAsync()); cancelled.Cancel(); release.SetResult(); Check(!await sending);
    Check(await vm.SendAsync() && sends == 1);
});
await Test("存档补齐单飞且失败不自动重发，设置目标无效不调用服务", async () =>
{
    int fills = 0, sets = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    await using var vm = new ArchiveViewModel((_, _) => Task.FromResult(new ListArchiveStatusResponse()),
        (request, ct) => { sets++; Check(request.ChatId == 153 && request.Enabled); return Task.FromResult(new SetDeepArchiveResponse()); },
        async (_, _) => { fills++; started.SetResult(); await release.Task; throw new IOException("fixture timeout"); }, new ImmediateDispatcher());
    var filling = vm.FillHoles.ExecuteAsync(new()); await started.Task;
    Check(!await vm.FillHoles.ExecuteAsync(new())); release.SetResult();
    Check(!await filling && vm.FillHoles.OutcomeUncertain && fills == 1);
    Check(!await vm.SetDeepArchive.ExecuteAsync(new() { ChatId = long.MaxValue, Enabled = true }) && sets == 0);
    Check(await vm.SetDeepArchive.ExecuteAsync(new() { ChatId = 153, Enabled = true }) && sets == 1);
    Check(await vm.Load.ExecuteAsync(new()));
});
await Test("资料目标固定，保留临时会话来源，拒绝错误资料和空会话标识", async () =>
{
    var peer = new Peer { PeerId = 42, Kind = PeerKind.User }; bool wrong = false;
    await using var vm = new ContactProfileViewModel(peer, 521409608,
        (request, ct) => { Check(request.UserId == 42 && request.Refresh); return Task.FromResult(new GetUserProfileResponse { Profile = new UserProfile { Peer = new Peer { PeerId = wrong ? 99 : 42, Kind = PeerKind.User } } }); },
        (_, _) => throw new Exception("不应调用群资料"),
        (request, ct) => { Check(request.PeerId == 42 && request.Scene == Scene.Friend && request.ViaGroupId == 521409608); return Task.FromResult(new OpenChatResponse { ChatId = wrong ? 0 : 153 }); }, new ImmediateDispatcher());
    peer.PeerId = 99;
    Check(await vm.Refresh.ExecuteAsync(new()) && vm.Refresh.Result!.PeerId == 42);
    Check(await vm.Open.ExecuteAsync(new()) && vm.Open.Result!.ChatId == 153);
    wrong = true; Check(!await vm.Refresh.ExecuteAsync(new()) && !await vm.Open.ExecuteAsync(new()));
});
await Test("状态页关闭抑制迟到结果，会话关闭等待状态请求释放传输", async () =>
{
    var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        Check(request.RequestUri!.AbsolutePath == "/qqbridge.v1.AdminService/GetStatus");
        started.SetResult(); await release.Task;
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new GetStatusResponse().ToByteArray()) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    await using var load = new RpcOperationViewModel<GetStatusRequest, GetStatusResponse>(session.GetStatusAsync, new ImmediateDispatcher(), false);
    var loading = load.ExecuteAsync(new()); await started.Task;
    load.Dispose(); var closing = session.DisposeAsync().AsTask();
    Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); Check(!await loading && load.Result is null);
    await closing; Check(handler.IsDisposed);
    try { await session.GetStatusAsync(new()); throw new Exception("关闭后应拒绝状态请求"); } catch (ObjectDisposedException) { }
});
await Test("存储媒体分页按原始数量推进，失败可重试，空页停止", async () =>
{
    int calls = 0;
    await using var vm = new StorageItemsViewModel(153, "image", (request, ct) =>
    {
        calls++; Check(request.ChatId == 153 && request.Categories.Single() == "image");
        Check(request.Offset == (calls == 1 ? 0u : calls <= 3 ? 2u : 4u));
        if (calls == 2) throw new IOException("fixture network failure");
        var response = new ListStorageItemsResponse { More = true };
        if (calls <= 3)
        {
            response.Items.Add(new StorageItem { Sha256 = new string('a', 64) });
            response.Items.Add(new StorageItem { Sha256 = new string(calls == 1 ? 'a' : 'b', 64) });
        }
        return Task.FromResult(response);
    }, new ImmediateDispatcher());
    Check(await vm.LoadMoreAsync() && vm.Items.Count == 1);
    Check(!await vm.LoadMoreAsync() && vm.HasMore && vm.Items.Count == 1);
    Check(await vm.LoadMoreAsync() && vm.Items.Count == 2);
    Check(await vm.LoadMoreAsync() && !vm.HasMore);
    Check(!await vm.LoadMoreAsync() && calls == 4);
});
await Test("存储媒体页面关闭不发布迟到内容，加载单飞", async () =>
{
    var started = new TaskCompletionSource(); var release = new TaskCompletionSource(); int calls = 0;
    await using var vm = new StorageItemsViewModel(153, "image", async (_, _) =>
    {
        calls++; started.SetResult(); await release.Task;
        var response = new ListStorageItemsResponse(); response.Items.Add(new StorageItem { Sha256 = new string('c', 64) }); return response;
    }, new ImmediateDispatcher());
    var loading = vm.LoadMoreAsync(); await started.Task;
    Check(!await vm.LoadMoreAsync() && calls == 1);
    vm.Dispose(); release.SetResult(); Check(!await loading && vm.Items.Count == 0);
});
await Test("存储概览及分类请求固定快照，关闭会话等待两项读取收尾", async () =>
{
    var started = new TaskCompletionSource(); var release = new TaskCompletionSource(); int entered = 0;
    var handler = new Handler(async request =>
    {
        if (Interlocked.Increment(ref entered) == 2) started.SetResult();
        await release.Task;
        var body = await request.Content!.ReadAsByteArrayAsync();
        byte[] response;
        if (request.RequestUri!.AbsolutePath.EndsWith("/GetStorageOverview"))
        {
            Check(GetStorageOverviewRequest.Parser.ParseFrom(body).Limit == 30);
            response = new GetStorageOverviewResponse().ToByteArray();
        }
        else
        {
            Check(request.RequestUri.AbsolutePath.EndsWith("/ListStorageChats"));
            var query = ListStorageChatsRequest.Parser.ParseFrom(body);
            Check(query.Limit == 200 && query.Categories.Single() == "image");
            response = new ListStorageChatsResponse().ToByteArray();
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var overview = new GetStorageOverviewRequest { Limit = 30 };
    var chats = new ListStorageChatsRequest { Limit = 200 }; chats.Categories.Add("image");
    var first = session.GetStorageOverviewAsync(overview); var second = session.ListStorageChatsAsync(chats);
    overview.Limit = 1; chats.Categories.Clear(); await started.Task;
    var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult();
    try { await first; } catch (OperationCanceledException) { }
    try { await second; } catch (OperationCanceledException) { }
    await closing; Check(handler.IsDisposed);
    try { await session.ListStorageChatsAsync(new()); throw new Exception("关闭后应拒绝读取"); } catch (ObjectDisposedException) { }
});
await Test("存储策略与清理请求纳入关闭等待，取消不自动重试", async () =>
{
    int entered = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        if (Interlocked.Increment(ref entered) == 5) started.SetResult();
        await release.Task;
        var body = await request.Content!.ReadAsByteArrayAsync();
        if (request.RequestUri!.AbsolutePath.EndsWith("/ExecuteCleanup"))
        { var parsed = ExecuteCleanupRequest.Parser.ParseFrom(body); Check(parsed.ChatId == 153 && parsed.OlderThanDays == 30); }
        if (request.RequestUri.AbsolutePath.EndsWith("/SetStoragePolicy"))
        { var parsed = SetStoragePolicyRequest.Parser.ParseFrom(body); Check(parsed.Policy.ChatId == 153 && parsed.Policy.HasKeepOriginalDays && parsed.Policy.KeepOriginalDays == 0 && !parsed.Policy.HasColdAfterDays); }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([]) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var setting = new SetStoragePolicyRequest { Policy = new StoragePolicy { Scope = PolicyScope.Chat, ChatId = 153, KeepOriginalDays = 0 } };
    var cleanup = new ExecuteCleanupRequest { ChatId = 153, OlderThanDays = 30 };
    Task[] requests = [session.ListStoragePoliciesAsync(new()), session.SetStoragePolicyAsync(setting),
        session.DeleteStoragePolicyAsync(new() { Scope = PolicyScope.Chat, ChatId = 153 }),
        session.PlanCleanupAsync(new() { ChatId = 153, OlderThanDays = 30 }), session.ExecuteCleanupAsync(cleanup)];
    setting.Policy.ClearKeepOriginalDays(); cleanup.OlderThanDays = 1;
    await started.Task; var closing = session.DisposeAsync().AsTask();
    Check(!closing.IsCompleted && !handler.IsDisposed); release.SetResult();
    foreach (var request in requests) { try { await request; } catch (OperationCanceledException) { } }
    await closing; Check(handler.IsDisposed && entered == 5);
    try { await session.ExecuteCleanupAsync(new() { ChatId = 153 }); throw new Exception("关闭后应拒绝清理"); } catch (ObjectDisposedException) { }
});
await Test("存储分类能力与后端一致，会话详情关闭不发布迟到结果", async () =>
{
    foreach (var category in new[] { "image", "qq_thumb", "sticker", "video", "record", "file", "group_file" })
        Check(StorageCategories.HasChats(category) && StorageCategories.HasMediaItems(category));
    foreach (var category in new[] { "avatar", "derived", "other", "unknown" })
        Check(!StorageCategories.HasChats(category) && !StorageCategories.HasMediaItems(category));
    Check(StorageCategories.HasChats("message") && !StorageCategories.HasMediaItems("message"));
    var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        Check(request.RequestUri!.AbsolutePath.EndsWith("/GetChatStorage"));
        var query = GetChatStorageRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()); Check(query.ChatId == 153);
        started.SetResult(); await release.Task;
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new GetChatStorageResponse { Summary = new() { ChatId = 153 } }.ToByteArray()) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    using var vm = new ChatStorageViewModel(153, session.GetChatStorageAsync, new ImmediateDispatcher());
    var loading = vm.LoadAsync(); await started.Task; vm.Dispose();
    var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); Check(!await loading && vm.Detail is null); await closing; Check(handler.IsDisposed);
});
await Test("群成员分页去重、失败重试及空页停止，保留缓存标记", async () =>
{
    int calls = 0;
    using var vm = new GroupMembersViewModel(521409608, (request, ct) =>
    {
        calls++; Check(request.GroupId == 521409608 && request.Limit == 100 && !request.Refresh);
        Check(request.Offset == (calls == 1 ? 0 : 2));
        if (calls == 2) throw new IOException("fixture failure");
        var page = new ListGroupMembersResponse { Total = 500, Stale = true };
        if (calls == 1) { page.Members.Add(new GroupMember { UserId = 42 }); page.Members.Add(new GroupMember { UserId = 42 }); }
        return Task.FromResult(page);
    }, new ImmediateDispatcher());
    Check(await vm.LoadMoreAsync() && vm.Members.Count == 1 && vm.Stale && vm.HasMore);
    Check(!await vm.LoadMoreAsync() && vm.Members.Count == 1 && vm.HasMore);
    Check(await vm.LoadMoreAsync() && !vm.HasMore && vm.Total == 500);
    Check(!await vm.LoadMoreAsync() && calls == 3);
});
await Test("群成员页释放后不发布迟到成员，账号关闭等待读取", async () =>
{
    var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        Check(request.RequestUri!.AbsolutePath.EndsWith("/ListGroupMembers")); started.SetResult(); await release.Task;
        var response = new ListGroupMembersResponse { Total = 1 }; response.Members.Add(new GroupMember { UserId = 42 });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    using var vm = new GroupMembersViewModel(521409608, session.ListGroupMembersAsync, new ImmediateDispatcher());
    var loading = vm.LoadMoreAsync(); await started.Task; Check(!await vm.LoadMoreAsync()); vm.Dispose();
    var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); Check(!await loading && vm.Members.Count == 0); await closing; Check(handler.IsDisposed);
});
await Test("群公告精华相册读取固定群号并在账号关闭时等待收尾", async () =>
{
    int entered = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        if (Interlocked.Increment(ref entered) == 4) started.SetResult(); await release.Task;
        var body = await request.Content!.ReadAsByteArrayAsync();
        long groupId = request.RequestUri!.AbsolutePath.Split('/').Last() switch
        {
            "ListGroupNotices" => ListGroupNoticesRequest.Parser.ParseFrom(body).GroupId,
            "ListGroupEssence" => ListGroupEssenceRequest.Parser.ParseFrom(body).GroupId,
            "ListGroupAlbums" => ListGroupAlbumsRequest.Parser.ParseFrom(body).GroupId,
            "ListGroupAlbumMedia" => ListGroupAlbumMediaRequest.Parser.ParseFrom(body).GroupId,
            _ => throw new Exception("非预期接口")
        };
        Check(groupId == 521409608);
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([]) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var notice = new ListGroupNoticesRequest { GroupId = 521409608 }; var essence = new ListGroupEssenceRequest { GroupId = 521409608 };
    var albums = new ListGroupAlbumsRequest { GroupId = 521409608 }; var media = new ListGroupAlbumMediaRequest { GroupId = 521409608, AlbumId = "fixture" };
    Task[] reads = [session.ListGroupNoticesAsync(notice), session.ListGroupEssenceAsync(essence), session.ListGroupAlbumsAsync(albums), session.ListGroupAlbumMediaAsync(media)];
    notice.GroupId = essence.GroupId = albums.GroupId = media.GroupId = 1;
    await started.Task; var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); foreach (var read in reads) { try { await read; } catch (OperationCanceledException) { } }
    await closing; Check(handler.IsDisposed && entered == 4);
});
await Test("精华初次加载期间媒体事件不丢失，读取期间后续事件继续追平", async () =>
{
    var listing = new TaskCompletionSource(); var listed = new TaskCompletionSource();
    var reading = new TaskCompletionSource(); var read = new TaskCompletionSource(); int reads = 0;
    using var vm = new GroupEssenceViewModel(async (_, _) =>
    {
        listing.SetResult(); await listed.Task;
        var response = new ListGroupEssenceResponse(); response.Items.Add(new GroupEssence { Seq = 7, Message = new Message { ChatId = 153, Seq = 7, Version = 1 } }); return response;
    }, async (request, _) =>
    {
        reads++; Check(request.ChatId == 153 && request.AnchorSeq == 7 && request.Direction == HistoryDirection.Around);
        if (reads == 1) { reading.SetResult(); await read.Task; }
        var response = new GetHistoryResponse(); response.Messages.Add(new Message { ChatId = 153, Seq = 7, Version = reads + 1 }); return response;
    }, new ImmediateDispatcher());
    var loading = vm.LoadAsync(521409608, default); await listing.Task;
    await vm.MediaReadyAsync(new() { ChatId = 153, Seq = 7 }, default);
    listed.SetResult(); await reading.Task;
    await vm.MediaReadyAsync(new() { ChatId = 153, Seq = 7 }, default);
    await vm.MediaReadyAsync(new() { ChatId = 99, Seq = 7 }, default);
    read.SetResult(); Check(await loading && reads == 2 && vm.Items.Single().Message.Version == 3);
});
await Test("精华刷新拒绝旧版本和关闭后迟到结果", async () =>
{
    bool delay = false; var started = new TaskCompletionSource(); var release = new TaskCompletionSource(); int changes = 0;
    using var vm = new GroupEssenceViewModel((_, _) =>
    {
        var response = new ListGroupEssenceResponse(); response.Items.Add(new GroupEssence { Seq = 7, Message = new Message { ChatId = 153, Seq = 7, Version = 5 } }); return Task.FromResult(response);
    }, async (_, _) =>
    {
        if (delay) { started.SetResult(); await release.Task; }
        var response = new GetHistoryResponse(); response.Messages.Add(new Message { ChatId = 153, Seq = 7, Version = delay ? 6 : 4 }); return response;
    }, new ImmediateDispatcher());
    vm.Changed += () => changes++;
    Check(await vm.LoadAsync(521409608, default));
    await vm.MediaReadyAsync(new() { ChatId = 153, Seq = 7 }, default); Check(vm.Items.Single().Message.Version == 5 && changes == 1);
    delay = true; var refreshing = vm.MediaReadyAsync(new() { ChatId = 153, Seq = 7 }, default); await started.Task;
    vm.Dispose(); release.SetResult(); await refreshing; Check(vm.Items.Single().Message.Version == 5 && changes == 1);
});
await Test("群文件全部读取与管理请求在账号关闭时收尾且不重发", async () =>
{
    int entered = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        if (Interlocked.Increment(ref entered) == 7) started.SetResult(); await release.Task;
        var body = await request.Content!.ReadAsByteArrayAsync();
        if (request.RequestUri!.AbsolutePath.EndsWith("/MoveGroupFiles"))
        { var move = MoveGroupFilesRequest.Parser.ParseFrom(body); Check(move.GroupId == 123 && move.FileIds.Single() == "original"); }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([]) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var move = new MoveGroupFilesRequest { GroupId = 123 }; move.FileIds.Add("original");
    Task[] operations = [session.ListGroupFilesAsync(new() { GroupId = 123 }), session.DeleteGroupFolderAsync(new() { GroupId = 123 }),
        session.DeleteGroupFilesAsync(new() { GroupId = 123 }), session.RenameGroupFileAsync(new() { GroupId = 123 }),
        session.MoveGroupFilesAsync(move), session.CreateGroupFolderAsync(new() { GroupId = 123 }), session.FetchGroupFileAsync(new() { GroupId = 123 })];
    move.FileIds.Clear(); await started.Task;
    var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); foreach (var operation in operations) { try { await operation; } catch (OperationCanceledException) { } }
    await closing; Check(handler.IsDisposed && entered == 7);
});
await Test("媒体提及回应读取及提及已读在账号关闭时收尾，序号快照不变", async () =>
{
    int entered = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        if (Interlocked.Increment(ref entered) == 4) started.SetResult(); await release.Task;
        if (request.RequestUri!.AbsolutePath.EndsWith("/MarkMentionsSeen"))
        {
            var mark = MarkMentionsSeenRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync());
            Check(mark.ChatId == 153 && mark.Seqs.SequenceEqual(new long[] { 7, 8 }));
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([]) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var mark = new MarkMentionsSeenRequest { ChatId = 153 }; mark.Seqs.AddRange(new long[] { 7, 8 });
    Task[] operations = [session.ListSharedMediaAsync(new() { ChatId = 153 }), session.ListUnreadMentionsAsync(new() { ChatId = 153 }),
        session.MarkMentionsSeenAsync(mark), session.ListReactionUsersAsync(new() { ChatId = 153, Seq = 7, EmojiId = "128077" })];
    mark.Seqs.Clear(); await started.Task;
    var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); foreach (var operation in operations) { try { await operation; } catch (OperationCanceledException) { } }
    await closing; Check(handler.IsDisposed && entered == 4);
});
await Test("退出账号等待表情准备，取消后不继续下一批或发布结果", async () =>
{
    int calls = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        calls++; Check(request.RequestUri!.AbsolutePath.EndsWith("/PrepareStickers"));
        var query = PrepareStickersRequest.Parser.ParseFrom(await request.Content!.ReadAsByteArrayAsync()); Check(query.Md5.Count == 60);
        started.SetResult(); await release.Task;
        var response = new PrepareStickersResponse();
        response.Stickers.Add(new Sticker { Md5 = query.Md5[0], Sha256 = new string('a', 64) });
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(response.ToByteArray()) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    using var vm = new StickerCatalogViewModel(session.ListStickersAsync, session.PrepareStickersAsync, session.AddStickerAsync, new ImmediateDispatcher());
    var preparing = vm.PrepareAsync(Enumerable.Range(1, 61).Select(i => i.ToString("x32")));
    await started.Task; vm.Dispose(); var closing = session.DisposeAsync().AsTask();
    Check(!closing.IsCompleted && !handler.IsDisposed); release.SetResult();
    Check(!await preparing && vm.Items.Count == 0); await closing; Check(calls == 1 && handler.IsDisposed);
});
await Test("后台联系人快照包含无会话联系人，旧快照不随缓存更新变更", async () =>
{
    using var store = new LocalStore(":memory:"); await using var repository = new LocalRepository(store);
    await using var vm = new DialogListViewModel(repository, new ImmediateDispatcher());
    var initial = new Difference { Pts = 1, IsFinal = true };
    initial.Peers.Add(new Peer { PeerId = 42, Kind = PeerKind.User, Name = "旧联系人", IsFriend = true, Pts = 1 });
    initial.Peers.Add(new Peer { PeerId = 42, Kind = PeerKind.Group, Name = "同号群", Pts = 1 });
    store.Apply(initial); Check(await vm.LoadAsync());
    var old = vm.Load.Result!.DisplayPeers;
    Check(vm.Items.Count == 0 && old.Count == 2 && old[(42, false)].Name == "旧联系人" && old[(42, true)].Name == "同号群");
    var update = new Difference { Pts = 2, IsFinal = true };
    update.Peers.Add(new Peer { PeerId = 42, Kind = PeerKind.User, Name = "新联系人", IsFriend = true, Pts = 2 });
    store.Apply(update); Check(await vm.LoadAsync());
    Check(old[(42, false)].Name == "旧联系人" && vm.Load.Result!.DisplayPeers[(42, false)].Name == "新联系人");
});
await Test("会话刷新复用联系人版本，重置返回空快照，外部修改不污染内部缓存", async () =>
{
    using var store = new LocalStore(":memory:"); await using var repository = new LocalRepository(store);
    var initial = new Difference { Pts = 1, IsFinal = true };
    initial.Peers.Add(new Peer { QqAccountId = 1, PeerId = 42, Kind = PeerKind.User, Name = "原名", Pts = 1 });
    initial.Dialogs.Add(new Dialog { QqAccountId = 1, ChatId = 153, PeerId = 42, Scene = Scene.Friend, DialogPts = 1 }); store.Apply(initial);
    var first = await repository.GetDialogDirectoryAsync(); Check(first.Peers?.Count == 1);
    var change = new Difference { Pts = 2, IsFinal = true };
    change.Dialogs.Add(new Dialog { QqAccountId = 1, ChatId = 153, PeerId = 42, Scene = Scene.Friend, DialogPts = 2, UnreadCount = 5 }); store.Apply(change);
    var same = await repository.GetDialogDirectoryAsync(knownPeerRevision: first.PeerRevision);
    Check(same.Peers is null && same.PeerRevision == first.PeerRevision && same.Dialogs.Single().UnreadCount == 5);
    await using var vm = new DialogListViewModel(repository, new ImmediateDispatcher()); Check(await vm.LoadAsync());
    vm.Load.Result!.DisplayPeers[(42, false)].Name = "外部修改";
    Check(await vm.LoadAsync() && vm.Items.Single().Title == "原名" && vm.Load.Result!.DisplayPeers[(42, false)].Name == "原名");
    store.Reset(); var reset = await repository.GetDialogDirectoryAsync(knownPeerRevision: first.PeerRevision);
    Check(reset.PeerRevision > first.PeerRevision && reset.Peers is { Count: 0 });
    Check(await vm.LoadAsync() && vm.Items.Count == 0 && vm.Load.Result!.DisplayPeers.Count == 0);
});
await Test("媒体请求固定嵌套引用，账号关闭等待头像签名与转发读取", async () =>
{
    int entered = 0; var started = new TaskCompletionSource(); var release = new TaskCompletionSource();
    var handler = new Handler(async request =>
    {
        if (Interlocked.Increment(ref entered) == 4) started.SetResult(); await release.Task;
        var body = await request.Content!.ReadAsByteArrayAsync();
        if (request.RequestUri!.AbsolutePath.EndsWith("/RequestMedia"))
        { var media = RequestMediaRequest.Parser.ParseFrom(body); Check(media.Original && media.Refs.Single().ChatId == 153 && media.Refs.Single().Seq == 7); }
        if (request.RequestUri.AbsolutePath.EndsWith("/GetForward"))
        { var forward = GetForwardRequest.Parser.ParseFrom(body); Check(forward.ChatId == 153 && forward.Path.SequenceEqual(new int[] { 1, 2 })); }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([]) };
    });
    var session = await ClientSessionRuntime.CreateAsync(new Uri("https://bridge.test"), "fixture", ":memory:", new ImmediateDispatcher(), handler: handler);
    var media = new RequestMediaRequest { Original = true }; media.Refs.Add(new MediaRef { ChatId = 153, Seq = 7 });
    var forward = new GetForwardRequest { ChatId = 153, Seq = 7 }; forward.Path.AddRange(new int[] { 1, 2 });
    Task[] operations = [session.RequestMediaAsync(media), session.GetForwardAsync(forward), session.GetAvatarsAsync(new()), session.SignMediaUrlsAsync(new())];
    media.Refs[0].ChatId = 999; forward.Path.Clear(); await started.Task;
    var closing = session.DisposeAsync().AsTask(); Check(!closing.IsCompleted && !handler.IsDisposed);
    release.SetResult(); foreach (var operation in operations) { try { await operation; } catch (OperationCanceledException) { } }
    await closing; Check(handler.IsDisposed && entered == 4);
});
await Test("媒体请求前到达的就绪事件被保留，重读可播放信息而非直接使用事件哈希", async () =>
{
    int calls = 0;
    var initial = new MediaInfo { State = MediaState.Pending, Ord = 2 };
    var coordinator = new MediaOpenCoordinator(153, 7, initial, (query, ct) =>
    {
        calls++; Check(query.Original && query.Refs.Single().Ord == 2);
        var response = new RequestMediaResponse(); response.Media.Add(calls == 1 ? new MediaInfo { State = MediaState.Pending }
            : new MediaInfo { State = MediaState.Stored, Sha256 = "original", PlayableSha256 = "playable", Mime = "video/mp4" }); return Task.FromResult(response);
    });
    initial.Ord = 99;
    coordinator.Notify(new() { ChatId = 153, Seq = 7, Ord = 2, Node = -1, State = "stored", Sha256 = "event" });
    var result = await coordinator.ResolveAsync(default);
    Check(calls == 2 && result.PlayableSha256 == "playable" && result.Mime == "video/mp4");
});
await Test("清理后的旧哈希必须重新请求，媒体等待忽略其他消息和缩略图并可取消", async () =>
{
    int calls = 0; var requested = new TaskCompletionSource();
    var coordinator = new MediaOpenCoordinator(153, 7, new MediaInfo { State = MediaState.Purged, Sha256 = "old", Ord = 2 }, (_, _) =>
    {
        calls++; requested.SetResult(); var response = new RequestMediaResponse(); response.Media.Add(new MediaInfo { State = MediaState.Pending }); return Task.FromResult(response);
    });
    using var cancel = new CancellationTokenSource(); var opening = coordinator.ResolveAsync(cancel.Token); await requested.Task;
    coordinator.Notify(new() { ChatId = 999, Seq = 7, Ord = 2, Node = -1, State = "stored" });
    coordinator.Notify(new() { ChatId = 153, Seq = 7, Ord = 2, Node = -1, Thumb = true, State = "stored" });
    coordinator.Notify(new() { ChatId = 153, Seq = 7, Ord = 2, Node = 0, State = "stored" });
    Check(!opening.IsCompleted && calls == 1); cancel.Cancel();
    try { await opening; throw new Exception("应取消等待"); } catch (OperationCanceledException) { }
    Check(calls == 1);
});
await Test("右栏页面栈：下钻入栈、同页替换、回到栈中页面时截断、根导航清栈", async () =>
{
    var shown = new List<string>();
    DetailDestination To(string key, string label) => new(key, () => { shown.Add(label); return Task.CompletedTask; });
    var nav = new DetailNavigator();
    Check(!nav.CanGoBack && !await nav.GoBackAsync());
    await nav.ResetAsync(To("chat:1", "聊天"));
    await nav.NavigateAsync(To("profile:1", "资料"));
    await nav.NavigateAsync(To("group:1:群成员", "成员"));
    Check(nav.Depth == 2 && nav.CanGoBack);
    await nav.NavigateAsync(To("group:1:群成员", "成员刷新"));
    Check(nav.Depth == 2 && nav.Current!.Key == "group:1:群成员");
    await nav.NavigateAsync(To("chat:1", "发消息回到聊天"));
    Check(nav.Depth == 0 && !nav.CanGoBack && nav.Current!.Key == "chat:1");
    await nav.NavigateAsync(To("profile:1", "资料"));
    Check(await nav.GoBackAsync() && shown[^1] == "发消息回到聊天" && nav.Depth == 0);
    await nav.NavigateAsync(To("prefs:1", "设置"));
    await nav.ResetAsync(To("chat:2", "另一个聊天"));
    Check(nav.Depth == 0 && nav.Current!.Key == "chat:2");
    for (int i = 0; i < DetailNavigator.MaxDepth + 5; i++) await nav.NavigateAsync(To("page:" + i, "页" + i));
    Check(nav.Depth == DetailNavigator.MaxDepth);
    var changed = new List<string?>(); nav.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
    nav.Clear();
    Check(nav.Current is null && !nav.CanGoBack && !nav.ShowsDetail && changed.Contains(nameof(DetailNavigator.CanGoBack)));
    await nav.ResetAsync(To("setting:连接与账号", "设置首页") with { Landing = true });
    Check(!nav.ShowsDetail);
    await nav.NavigateAsync(To("setting:存储", "存储"));
    Check(nav.ShowsDetail && nav.CanGoBack);
    await nav.GoBackAsync();
    Check(!nav.ShowsDetail && nav.Current!.Landing);
});
await Test("导航未读角标与 iOS 规则一致", () =>
{
    Dialog D(string policy) => new() { ChatId = 1, NotifyPolicy = policy, UnreadCount = 9, UnreadMentions = 2, UnreadReplies = 1, UnreadMentionAll = 4 };
    Check(DialogBadge.Count(D("")) == 9 && DialogBadge.Count(D("all")) == 9);
    Check(DialogBadge.Count(D("muted")) == 3 && DialogBadge.Count(D("archived")) == 3 && DialogBadge.Count(D("mentions")) == 3);
    Check(new DialogRowViewModel(D("muted")).BadgeCount == 3);
    return Task.CompletedTask;
});
await Test("连接提示：同步只写小字，横幅只留连不上、要重新登录和 QQ 掉线", () =>
{
    Check(ConnectionNotice.Describe("正在连接…", null) == new ConnectionNotice(true, null, false));
    Check(ConnectionNotice.Describe("首屏预取失败，打开会话时重试", null).Syncing);
    Check(ConnectionNotice.Describe("已连接", null) == ConnectionNotice.None);
    Check(ConnectionNotice.Describe("已连接", true) == ConnectionNotice.None);
    Check(ConnectionNotice.Describe("已连接", false) is { OffersQqLogin: true, Syncing: false, Message.Length: > 0 });
    Check(ConnectionNotice.Describe("连接中断，8 秒后重试", false) == new ConnectionNotice(false, "连不上服务器，8 秒后重试", false));
    Check(ConnectionNotice.Describe("设备令牌已失效，请重新连接", null).Message == "需要重新登录");
    Check(ConnectionNotice.Describe("尚未连接", null) == ConnectionNotice.None);
    return Task.CompletedTask;
});
await Test("会话行时间、未读文字、免打扰切换和发送者前缀与 iOS 一致", () =>
{
    var zone = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");
    // 2026-10-17（星期六）10:00 北京时间
    var now = new DateTimeOffset(2026, 10, 17, 2, 0, 0, TimeSpan.Zero);
    long At(int day, int hour) => new DateTimeOffset(2026, 10, day, hour, 30, 0, TimeSpan.FromHours(8)).ToUnixTimeSeconds();
    Check(!DialogListFormat.HasVisibleText("\u2062") && !DialogListFormat.HasVisibleText("\u3164 \u200B") && !DialogListFormat.HasVisibleText(""));
    Check(DialogListFormat.HasVisibleText("\u3000old blue") && DialogListFormat.HasVisibleText("-"));
    Check(DialogListFormat.ListTime(0, now, zone) == "");
    Check(DialogListFormat.ListTime(At(17, 0), now, zone) == "00:30");
    Check(DialogListFormat.ListTime(At(16, 23), now, zone) == "昨天");
    Check(DialogListFormat.ListTime(At(12, 9), now, zone) == "星期一");
    Check(DialogListFormat.ListTime(At(10, 9), now, zone) == "26/10/10");
    Check(DialogListFormat.UnreadText(0) == "" && DialogListFormat.UnreadText(99) == "99" && DialogListFormat.UnreadText(100) == "99+");
    var group = new Dialog { ChatId = 1, Scene = Scene.Group, NotifyPolicy = "default" };
    var friend = new Dialog { ChatId = 2, Scene = Scene.Friend, NotifyPolicy = "muted" };
    Check(DialogListFormat.ToggleMutedPolicy(group) == "muted" && DialogListFormat.ToggleMutedPolicy(friend) == "default");
    Check(DialogListFormat.ToggleMutedPolicy(new Dialog { Scene = Scene.Group, NotifyPolicy = "archived" }) == "all");
    Check(DialogListFormat.ToggleArchivedPolicy(group) == "archived" && DialogListFormat.ToggleArchivedPolicy(new Dialog { NotifyPolicy = "archived" }) == "muted");
    var own = new HashSet<long> { 10 };
    group.TopMessage = new Message { Seq = 5, Kind = MessageKind.Normal, SenderId = 20, SenderName = "一二三四五六七八九十十一" };
    Check(DialogListFormat.SenderPrefix(group, own) == "一二三四五六七八九十…：");
    group.TopMessage.SenderId = 10; Check(DialogListFormat.SenderPrefix(group, own) == "我：");
    friend.TopMessage = new Message { Seq = 5, Kind = MessageKind.Normal, SenderId = 20, SenderName = "好友" };
    Check(DialogListFormat.SenderPrefix(friend, own) == "");
    group.Draft = new Draft(); group.Draft.Segments.Add(new OutgoingSegment { Text = "草稿" });
    Check(DialogListFormat.SenderPrefix(group, own) == "");
    group.Draft = null; group.TopMessage.Kind = MessageKind.Service; Check(DialogListFormat.SenderPrefix(group, own) == "");
    return Task.CompletedTask;
});
await Test("聊天页时间分隔、发送者合并、链接识别与卡片解析与 iOS 一致", () =>
{
    var own = new HashSet<long> { 1 };
    ChatPresentation.TimelineItem M(long t, long s) => new(t, s, true);
    var layout = ChatPresentation.Layout([M(1000, 2), M(1060, 2), M(1100, 3), new(1110, 0, false), M(1120, 3), M(1500, 3), M(1510, 1)], true, own);
    Check(layout[0] == new ChatPresentation.TimelineLayout(true, true));
    Check(layout[1] == new ChatPresentation.TimelineLayout(false, false));
    Check(layout[2] == new ChatPresentation.TimelineLayout(false, true));
    Check(layout[3] == new ChatPresentation.TimelineLayout(false, false));
    Check(layout[4].ShowsSender && !layout[4].ShowsTime);
    Check(layout[5] == new ChatPresentation.TimelineLayout(true, true));
    Check(!layout[6].ShowsSender);
    Check(ChatPresentation.Layout([M(1000, 2)], false, own)[0] == new ChatPresentation.TimelineLayout(true, false));

    var zone = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");
    var now = new DateTimeOffset(2026, 10, 17, 2, 0, 0, TimeSpan.Zero);
    long At(int y, int mo, int d) => new DateTimeOffset(y, mo, d, 14, 5, 0, TimeSpan.FromHours(8)).ToUnixTimeSeconds();
    Check(ChatPresentation.TimeHeader(At(2026, 10, 17), now, zone) == "14:05");
    Check(ChatPresentation.TimeHeader(At(2026, 10, 16), now, zone) == "昨天 14:05");
    Check(ChatPresentation.TimeHeader(At(2026, 10, 12), now, zone) == "星期一 14:05");
    Check(ChatPresentation.TimeHeader(At(2026, 3, 2), now, zone) == "3月2日 14:05");
    Check(ChatPresentation.TimeHeader(At(2025, 12, 31), now, zone) == "2025年12月31日 14:05");

    var runs = ChatPresentation.Linkify("看 https://example.com/a?b=1。加我 1114096791 或 www.qq.com, 编号 0x12345a 和 2026");
    Check(runs.Count(r => r.Kind == ChatPresentation.TextRunKind.Link) == 2);
    Check(runs.First(r => r.Kind == ChatPresentation.TextRunKind.Link).Target == "https://example.com/a?b=1");
    Check(runs.Last(r => r.Kind == ChatPresentation.TextRunKind.Link).Target == "https://www.qq.com");
    Check(runs.Single(r => r.Kind == ChatPresentation.TextRunKind.Number).Text == "1114096791");
    Check(string.Concat(runs.Select(r => r.Text)) == "看 https://example.com/a?b=1。加我 1114096791 或 www.qq.com, 编号 0x12345a 和 2026");
    Check(ChatPresentation.Linkify("").Count == 0);

    var mini = ChatPresentation.ParseAppCard("""{"prompt":"[QQ小程序]哔哩哔哩","meta":{"detail_1":{"appid":"1109937557","title":"哔哩哔哩","desc":"视频标题","preview":"pic.qq.com/x.png","qqdocurl":"http://b23.tv/abc","url":"m.q.qq.com/a"}}}""", "com.tencent.miniapp");
    Check(mini is { Source: "哔哩哔哩", Title: "视频标题", Description: "", Preview: "https://pic.qq.com/x.png", Url: "https://b23.tv/abc" });
    var share = ChatPresentation.ParseAppCard("""{"prompt":"[分享]文章","meta":{"news":{"title":"文章","desc":"摘要","tag":"知乎","jumpUrl":"mqqapi://x","url":"https://zhihu.com/q"}}}""", "com.tencent.structmsg");
    Check(share is { Source: "知乎", Title: "文章", Description: "摘要", Url: "https://zhihu.com/q" });
    Check(ChatPresentation.ParseAppCard("""{"meta":{"x":{}}}""", "a") is null && ChatPresentation.ParseAppCard("坏的", "a") is null);
    Check(ChatPresentation.CardText("""{"prompt":"[群公告]"}""") == "[群公告]" && ChatPresentation.CardText("""{"meta":{"a":{"desc":"说明"}}}""") == "[卡片] 说明");

    Check(ChatPresentation.Unsupported("nt:9", """{"walletElement":{"receiver":{"title":"恭喜发财"}}}""") is { Title: "QQ红包", Subtitle: "恭喜发财" });
    Check(ChatPresentation.Unsupported("nt:13", """{"structLongMsgElement":{"xmlContent":"<msg brief=\"[长消息]\"><summary>点击查看</summary></msg>"}}""").Subtitle == "点击查看");
    Check(ChatPresentation.Unsupported("nt:99", """{"arkElement":null,"zzElement":{},"extBufForUI":{}}""").Subtitle == "zzElement");
    Check(ChatPresentation.Unsupported("nt:99", "不是 JSON").Subtitle == "nt:99");

    Check(ChatPresentation.EventText("member_join", """{"via":"invite"}""", "甲", "乙", false) == "甲 邀请 乙 加入了群聊");
    Check(ChatPresentation.EventText("member_join", """{"via":"approve"}""", "管理", "乙", false) == "乙 加入了群聊");
    Check(ChatPresentation.EventText("member_leave", """{"how":"kick"}""", "甲", "乙", false) == "乙 被 甲 移出了群聊");
    Check(ChatPresentation.EventText("mute", """{"duration":7380}""", "甲", "乙", false) == "乙 被 甲 禁言 2 小时 3 分");
    Check(ChatPresentation.EventText("mute", "{}", "甲", "", false) == "甲 开启了全员禁言");
    Check(ChatPresentation.EventText("unmute", "{}", "", "乙", false) == "乙 被解除禁言");
    Check(ChatPresentation.EventText("call", """{"result":"answered","durationSec":125,"media":"audio"}""", "甲", "", false) == "语音通话 2:05");
    Check(ChatPresentation.EventText("call", """{"group":true,"media":"video"}""", "甲", "", false) == "甲 发起的群视频通话已结束");
    Check(ChatPresentation.EventText("gray_tip", """{"text":"灰条"}""", "", "", false) == "灰条");
    Check(ChatPresentation.EventText("poke", "坏", "甲", "乙", false) == "甲 戳了戳 乙" && ChatPresentation.EventText("x", "{}", "", "", false) == "[x]");
    return Task.CompletedTask;
});
await Test("同步第一次 GetState 之前先用登录时的账号列表认出自己", () =>
{
    var sync = new SyncEngine(null!, null!);
    Check(sync.OwnUsers.Count == 0);
    sync.SeedOwnUsers([1114096791, 0]);
    Check(sync.OwnUsers.SetEquals([1114096791L]));
    sync.SeedOwnUsers([42]);
    Check(sync.OwnUsers.SetEquals([1114096791L]));
    return Task.CompletedTask;
});
Console.WriteLine($"全部 {passed} 项测试通过。");
sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> handler) : HttpMessageHandler
{
    public bool IsDisposed { get; private set; }
    protected override void Dispose(bool disposing) { IsDisposed = true; base.Dispose(disposing); }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => handler(request);
}
sealed class FragmentedStream(byte[] data) : MemoryStream(data)
{
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => base.ReadAsync(buffer[..Math.Min(2, buffer.Length)], cancellationToken);
}
sealed class InterruptedUploadStream(bool truncate) : MemoryStream(new byte[10])
{
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (!truncate) return ValueTask.FromResult(0);
        SetLength(2); return base.ReadAsync(buffer, cancellationToken);
    }
}
sealed class TestVoiceRecorder : IVoiceRecorder
{
    public Task StartWait = Task.CompletedTask, FinishWait = Task.CompletedTask;
    public TimeSpan Duration = TimeSpan.FromSeconds(2);
    public bool Active;
    public int Finishes, Disposals;
    public async Task StartAsync(CancellationToken ct) { await StartWait; Active = true; }
    public async Task<RecordedVoice> FinishAsync(CancellationToken ct) { Finishes++; await FinishWait; Active = false; return new(new byte[] { 1, 2, 3 }, Duration); }
    public Task CancelAsync() { Active = false; return Task.CompletedTask; }
    public ValueTask DisposeAsync() { Disposals++; Active = false; return ValueTask.CompletedTask; }
}
sealed class RecordingClock : TimeProvider
{
    public Action? Fire;
    public TimeSpan Due;
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        Due = dueTime; var timer = new RecordingTimer(() => callback(state)); Fire = timer.Fire; return timer;
    }
    private sealed class RecordingTimer(Action callback) : ITimer
    {
        private bool disposed;
        public void Fire() { if (!disposed) callback(); }
        public bool Change(TimeSpan dueTime, TimeSpan period) => !disposed;
        public void Dispose() => disposed = true;
        public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
    }
}

sealed class ImmediateDispatcher : IUiDispatcher
{
    public Task InvokeAsync(Action action) { action(); return Task.CompletedTask; }
}

public class StoreProxy : DispatchProxy
{
    public Func<MethodInfo, object?[]?, object?> InvokeStore { get; set; } = null!;
    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args) => InvokeStore(targetMethod!, args);
}

sealed class QueuedDispatcher : IUiDispatcher
{
    private readonly System.Threading.Channels.Channel<Action> queue = System.Threading.Channels.Channel.CreateUnbounded<Action>();
    public Task InvokeAsync(Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        queue.Writer.TryWrite(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } });
        return completion.Task;
    }
    public async Task<Action> NextAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        return await queue.Reader.ReadAsync(timeout.Token);
    }
}

class StoreReadProbe : DispatchProxy
{
    public ILocalStore Target = null!;
    public int DialogReads;
    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        if (targetMethod!.Name == "get_Dialogs") DialogReads++;
        try { return targetMethod.Invoke(Target, args); }
        catch (TargetInvocationException error) when (error.InnerException is not null)
        { System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error.InnerException).Throw(); throw; }
    }
}
sealed class TestCallAudio : ICallAudioSession
{
    public bool FailPrepare, FailJoin;
    public int Joins, Leaves;
    public Func<Task>? JoinWait;
    public Task PrepareAsync(CancellationToken ct) => FailPrepare ? Task.FromException(new NotSupportedException("fixture")) : Task.CompletedTask;
    public async Task JoinAsync(Uri server, string token, string room, CancellationToken ct)
    {
        Joins++;
        if (token != "fixture-token" || room != "room") throw new Exception("凭据传递错误");
        if (FailJoin) throw new IOException("fixture join failure");
        if (JoinWait is not null) await JoinWait();
    }
    public Task LeaveAsync(CancellationToken ct) { Leaves++; return Task.CompletedTask; }
}

