using Google.Protobuf;
using Microsoft.Data.Sqlite;
using Qqbridge.V1;

namespace BetterChat.Core;

// 数据和游标在同一事务提交，进程退出后不能出现“游标前进但消息丢失”。
public sealed class LocalStore : ILocalStore
{
    private readonly SqliteConnection db;
    private readonly object gate = new();
    public event Action? Changed;
    public event Action? DialogsChanged;
    public event Action? PeersChanged;
    public long PeerRevision => Interlocked.Read(ref peerRevision);
    private long peerRevision;
    public long DialogRevision => Interlocked.Read(ref dialogRevision);
    private long dialogRevision;
    private long contactsRevision;
    public long ContactsRevision => Interlocked.Read(ref contactsRevision);
    public LocalStore(string path)
    {
        db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path }.ToString());
        try
        {
            db.Open();
            using var versionCommand = db.CreateCommand();
            versionCommand.CommandText = "PRAGMA user_version";
            var version = Convert.ToInt32(versionCommand.ExecuteScalar());
            // 拒绝用旧客户端写入新格式；无版本缓存先接管为 v1，再事务迁移，不重建用户数据。
            if (version > 2) throw new NotSupportedException($"本地数据库版本 {version} 高于客户端支持的版本 2。");
            Execute("PRAGMA journal_mode=WAL");
            if (version == 0)
            {
                using var transaction = db.BeginTransaction();
                Execute("CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL, key TEXT NOT NULL, chat INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 0, data BLOB NOT NULL, PRIMARY KEY(kind,key)); CREATE INDEX IF NOT EXISTS records_chat_seq ON records(kind,chat,seq); CREATE TABLE IF NOT EXISTS cursors(key TEXT PRIMARY KEY, value INTEGER NOT NULL); PRAGMA user_version=1;");
                transaction.Commit();
            }
            if (version < 2)
            {
                using var transaction = db.BeginTransaction();
                Execute("ALTER TABLE records ADD COLUMN active_outbox INTEGER NOT NULL DEFAULT 0");
                foreach (var entry in Read("outbox", OutboxEntry.Parser))
                    if (entry.State != OutboxState.Sent) Execute("UPDATE records SET active_outbox=1 WHERE kind='outbox' AND key=$0", entry.ClientRandomId.ToString());
                Execute("CREATE INDEX records_active_outbox ON records(chat,seq) WHERE kind='outbox' AND active_outbox=1; PRAGMA user_version=2;");
                transaction.Commit();
            }
            RecoverLegacyPendingIds();
        }
        catch { db.Dispose(); throw; }
    }
    private void Execute(string sql, params object[] args)
    {
        using var cmd = db.CreateCommand(); cmd.CommandText = sql;
        for (int i = 0; i < args.Length; i++) cmd.Parameters.AddWithValue("$" + i, args[i]);
        cmd.ExecuteNonQuery();
    }
    private void RecoverLegacyPendingIds()
    {
        // 仅修复旧 Windows 生成的正数越界 ID；后端在写入前拒绝它们，不存在重复发送风险。
        // 合法但未确认的 ID 必须原样保留，不能把网络超时误判为服务端没有收到。
        using var tx = db.BeginTransaction();
        var pending = Read("pending", SendMessageRequest.Parser);
        using var lookup = db.CreateCommand();
        lookup.CommandText = "SELECT EXISTS(SELECT 1 FROM records WHERE kind IN ('pending','outbox') AND key=$id)";
        var parameter = lookup.Parameters.AddWithValue("$id", "");
        bool Exists(long id) { parameter.Value = id.ToString(); return Convert.ToInt64(lookup.ExecuteScalar()) != 0; }
        foreach (var request in pending.Where(x => x.ClientRandomId > BetterChat.Application.MessageIdentity.MaxValue))
        {
            long previous = request.ClientRandomId;
            using var confirmed = db.CreateCommand();
            confirmed.CommandText = "SELECT EXISTS(SELECT 1 FROM records WHERE kind='outbox' AND key=$id)";
            confirmed.Parameters.AddWithValue("$id", previous.ToString());
            if (Convert.ToInt64(confirmed.ExecuteScalar()) != 0) continue;
            long replacement;
            do { replacement = BetterChat.Application.MessageIdentity.Create(); } while (Exists(replacement));
            request.ClientRandomId = replacement;
            Put("pending", replacement.ToString(), request, 0, request.ChatId);
            Execute("DELETE FROM records WHERE kind='pending' AND key=$0", previous.ToString());
        }
        tx.Commit();
    }
    public long Cursor(string key = "global")
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT value FROM cursors WHERE key=$key";
            cmd.Parameters.AddWithValue("$key", key);
            return Convert.ToInt64(cmd.ExecuteScalar() ?? 0L);
        }
    }
    private void SetCursor(string key, long value) => Execute("INSERT INTO cursors VALUES($0,$1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value);
    private void Put(string kind, string key, IMessage data, long version, long chat = 0, long seq = 0) => Execute(
        "INSERT INTO records(kind,key,chat,seq,version,data,active_outbox) VALUES($0,$1,$2,$3,$4,$5,$6) ON CONFLICT(kind,key) DO UPDATE SET data=excluded.data,version=excluded.version,active_outbox=excluded.active_outbox WHERE excluded.version>=records.version",
        kind, key, chat, seq, version, data.ToByteArray(), kind == "outbox" && data is OutboxEntry entry && entry.State != OutboxState.Sent ? 1 : 0);
    private void Atomic(Action action, bool dialogsChanged = false, bool peersChanged = false)
    {
        lock (gate)
        {
            using var tx = db.BeginTransaction(); action(); tx.Commit();
            if (dialogsChanged) Interlocked.Increment(ref dialogRevision);
            if (peersChanged) Interlocked.Increment(ref peerRevision);
        }
        if (dialogsChanged) DialogsChanged?.Invoke();
        if (peersChanged) PeersChanged?.Invoke();
        Changed?.Invoke();
    }
    public List<T> Read<T>(string kind, MessageParser<T> parser, long? chat = null) where T : IMessage<T>
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT data FROM records WHERE kind=$kind" + (chat.HasValue ? " AND chat=$chat ORDER BY seq" : "");
            cmd.Parameters.AddWithValue("$kind", kind);
            if (chat.HasValue) cmd.Parameters.AddWithValue("$chat", chat.Value);
            using var reader = cmd.ExecuteReader(); var result = new List<T>();
            while (reader.Read()) result.Add(parser.ParseFrom((byte[])reader[0]));
            return result;
        }
    }
    // 只解码当前取过的历史页和新消息，避免进入一个群就扫描整份存档。
    public List<T> ReadWindow<T>(string kind, MessageParser<T> parser, long chat, IEnumerable<string> keys, long? newerThan) where T : IMessage<T>
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = WindowQuery(newerThan.HasValue);
            cmd.Parameters.AddWithValue("$kind", kind); cmd.Parameters.AddWithValue("$chat", chat);
            cmd.Parameters.AddWithValue("$keys", System.Text.Json.JsonSerializer.Serialize(keys.Distinct()));
            if (newerThan.HasValue) cmd.Parameters.AddWithValue("$boundary", newerThan.Value);
            using var reader = cmd.ExecuteReader(); var result = new List<T>();
            while (reader.Read()) result.Add(parser.ParseFrom((byte[])reader[0]));
            return result;
        }
    }
    internal static string WindowQuery(bool includeNewer)
    {
        // CROSS JOIN 固定先枚举可见主键，避免 SQLite 为满足排序而扫描整个会话索引。
        // 两部分的序号范围互斥，用 UNION ALL 避免对消息 BLOB 做去重排序。
        var selected = "SELECT r.seq,r.data FROM json_each($keys) AS wanted CROSS JOIN records AS r ON r.kind=$kind AND r.key=wanted.value WHERE r.chat=$chat";
        if (includeNewer)
            selected += " AND r.seq<=$boundary UNION ALL SELECT seq,data FROM records WHERE kind=$kind AND chat=$chat AND seq>$boundary";
        return "SELECT data FROM (" + selected + ") ORDER BY seq";
    }
    public Dialog? ReadDialog(long chat)
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandText = "SELECT data FROM records WHERE kind='dialog' AND key=$key";
            cmd.Parameters.AddWithValue("$key", chat.ToString());
            return cmd.ExecuteScalar() is byte[] data ? Dialog.Parser.ParseFrom(data) : null;
        }
    }
    public List<Dialog> Dialogs => Read("dialog", Dialog.Parser).OrderByDescending(x => x.Pinned).ThenByDescending(x => x.Pinned ? x.PinnedAt : x.TopTime).ToList();
    public List<Peer> Peers => Read("peer", Peer.Parser);
    public BetterChat.Application.DialogDirectorySnapshot ReadDialogDirectory(long knownPeerRevision = -1)
    {
        // 同一连接的同步写入也使用此锁，防止两次查询之间切换到另一份已提交资料。
        lock (gate) return new(Dialogs, knownPeerRevision == peerRevision ? null : Peers, peerRevision);
    }
    public List<Message> Messages(long chat) => Read("message", Message.Parser, chat);
    public BetterChat.Application.TimelineSnapshot ReadTimeline(BetterChat.Application.TimelineQuery query)
    {
        lock (gate)
        {
            // pending 被确认后会移入 outbox，四份数据一起读取，避免交错时短暂消失或重复。
            return new(
                ReadWindow("message", Message.Parser, query.ChatId, query.Sequences.Select(s => $"{query.ChatId}:{s}"), query.NewerThan),
                ReadWindow("event", ChatEvent.Parser, query.ChatId, query.EventIds.Select(id => $"{query.ChatId}:{id}"), query.NewerThanTime),
                query.IncludeOutgoing ? ReadUnconfirmedPending(query.ChatId) : [],
                query.IncludeOutgoing ? ReadActiveOutbox(query.ChatId) : []);
        }
    }
    internal const string ActiveOutboxQuery = "SELECT data FROM records INDEXED BY records_active_outbox WHERE kind='outbox' AND active_outbox=1 AND chat=$chat ORDER BY seq";
    private List<OutboxEntry> ReadActiveOutbox(long chat)
    {
        using var cmd = db.CreateCommand(); cmd.CommandText = ActiveOutboxQuery; cmd.Parameters.AddWithValue("$chat", chat);
        using var reader = cmd.ExecuteReader(); var result = new List<OutboxEntry>();
        while (reader.Read()) result.Add(OutboxEntry.Parser.ParseFrom((byte[])reader[0]));
        return result;
    }
    private List<SendMessageRequest> ReadUnconfirmedPending(long chat)
    {
        // 已确认的本地项以前由 UI 扫描全部发件箱去重；现在逐个主键检查，已发送存档无需解码。
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT p.data FROM records AS p WHERE p.kind='pending' AND p.chat=$chat AND NOT EXISTS(SELECT 1 FROM records AS o WHERE o.kind='outbox' AND o.key=p.key) ORDER BY p.seq";
        cmd.Parameters.AddWithValue("$chat", chat);
        using var reader = cmd.ExecuteReader(); var result = new List<SendMessageRequest>();
        while (reader.Read()) result.Add(SendMessageRequest.Parser.ParseFrom((byte[])reader[0]));
        return result;
    }
    public void Apply(Difference d) => Atomic(() =>
    {
        foreach (var x in d.Dialogs)
        {
            Put("dialog", x.ChatId.ToString(), x, x.DialogPts);
            ClearMatchingLocalDraft(x.ChatId);
        }
        foreach (var x in d.Peers) Put("peer", $"{x.QqAccountId}:{(int)x.Kind}:{x.PeerId}", x, x.Pts);
        foreach (var x in d.Outbox)
        {
            Put("outbox", x.ClientRandomId.ToString(), x, x.Pts, x.ChatId);
            ReconcilePending(x);
        }
        foreach (var x in d.Tombstones) ApplyTombstone(x);
        SetCursor("global", Math.Max(Cursor(), d.Pts));
    }, d.Dialogs.Count > 0 || d.Tombstones.Any(t => t.Entity is "dialog" or "chat"), d.Peers.Count > 0);
    private void ApplyTombstone(Tombstone x)
    {
        if (x.Entity is "dialog" or "chat")
        {
            Execute("DELETE FROM records WHERE kind='dialog' AND key=$0", x.Key);
            if (long.TryParse(x.Key, out long chat))
            {
                Execute("DELETE FROM records WHERE chat=$0", chat);
                Execute("DELETE FROM cursors WHERE key=$0", "chat:" + chat);
            }
        }
        else if (x.Entity == "outbox") Execute("DELETE FROM records WHERE kind='outbox' AND key=$0", x.Key);
    }
    public void ApplyChat(long chat, long pts, IEnumerable<Message> messages, IEnumerable<ChatEvent> events, bool reset = false) => Atomic(() =>
    {
        if (reset) Execute("DELETE FROM records WHERE chat=$0 AND kind IN ('message','event','history')", chat);
        foreach (var x in messages) Put("message", $"{chat}:{x.Seq}", x, x.Version, chat, x.Seq);
        foreach (var x in events) Put("event", $"{chat}:{x.Id}", x, x.Version, chat, x.Time);
        SetCursor("chat:" + chat, Math.Max(reset ? 0 : Cursor("chat:" + chat), pts));
    });
    // 翻历史不推进 chat_pts，否则会跳过尚未应用的实时变化。
    public void MergeHistory(long chat, IEnumerable<Message> messages, IEnumerable<ChatEvent> events) => Atomic(() =>
    {
        foreach (var x in messages) Put("message", $"{chat}:{x.Seq}", x, x.Version, chat, x.Seq);
        foreach (var x in events) Put("event", $"{chat}:{x.Id}", x, x.Version, chat, x.Time);
    });
    public void SavePending(SendMessageRequest request) => Atomic(() =>
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT data FROM records WHERE kind='pending' AND key=$id";
        command.Parameters.AddWithValue("$id", request.ClientRandomId.ToString());
        if (command.ExecuteScalar() is byte[] bytes && !SendMessageRequest.Parser.ParseFrom(bytes).Equals(request))
            throw new InvalidOperationException("同一幂等 ID 的待发送内容不能更改，请创建新消息。");
        command.CommandText = "SELECT data FROM records WHERE kind='outbox' AND key=$id";
        if (command.ExecuteScalar() is byte[] accepted)
        {
            var entry = OutboxEntry.Parser.ParseFrom(accepted);
            if (entry.ChatId != request.ChatId || entry.ReplyToSeq != request.ReplyToSeq || !entry.Segments.SequenceEqual(request.Segments))
                throw new InvalidOperationException("此幂等 ID 已用于其他消息内容，请创建新消息。");
        }
        Put("pending", request.ClientRandomId.ToString(), request, 0, request.ChatId);
    });
    public void SaveLocalDraft(SaveDraftRequest request) => Atomic(() =>
        Put("local_draft", request.ChatId.ToString(), request, 0, request.ChatId));
    public SaveDraftRequest? ReadLocalDraft(long chat) => Read("local_draft", SaveDraftRequest.Parser, chat).SingleOrDefault();
    public void ConfirmLocalDraft(long chat) => Atomic(() => ClearMatchingLocalDraft(chat));
    private void ClearMatchingLocalDraft(long chat)
    {
        var local = ReadLocalDraft(chat);
        if (local is null) return;
        using var cmd = db.CreateCommand();
        cmd.CommandText = "SELECT data FROM records WHERE kind='dialog' AND key=$id";
        cmd.Parameters.AddWithValue("$id", chat.ToString());
        if (cmd.ExecuteScalar() is not byte[] bytes) return;
        var dialog = Dialog.Parser.ParseFrom(bytes);
        var confirmed = new SaveDraftRequest { ChatId = chat, ReplyToSeq = dialog.Draft?.ReplyToSeq ?? 0 };
        if (dialog.Draft is { } draft) confirmed.Segments.AddRange(draft.Segments);
        // changed 不是同步版本；只在同步快照确实包含当前本地内容时清除覆盖层。
        if (confirmed.Equals(local)) Execute("DELETE FROM records WHERE kind='local_draft' AND key=$0", chat.ToString());
    }
    public void MergeHistoryPage(long chat, GetHistoryResponse page, bool latest)
    {
        if (page.Messages.Any(m => m.ChatId != chat) || page.Events.Any(e => e.ChatId != chat))
            throw new IOException("历史响应包含其他会话的数据。");
        Atomic(() =>
        {
            foreach (var x in page.Messages) Put("message", $"{chat}:{x.Seq}", x, x.Version, chat, x.Seq);
            foreach (var x in page.Events) Put("event", $"{chat}:{x.Id}", x, x.Version, chat, x.Time);
            if (latest) Put("history", chat.ToString(), page, page.ChatPts, chat);
        });
    }
    public GetHistoryResponse? LatestHistory(long chat) => Read("history", GetHistoryResponse.Parser, chat).FirstOrDefault();
    public void SaveLatestHistory(long chat, GetHistoryResponse page) => Atomic(() => Put("history", chat.ToString(), page, page.ChatPts, chat));
    public bool TryApplyFirstScreen(long chat, GetHistoryResponse page, bool reset)
    {
        if (page.ChatPts < 0 || page.Messages.Any(x => x.ChatId != chat) || page.Events.Any(x => x.ChatId != chat))
            throw new ArgumentException("首屏快照包含无效游标或其他会话的数据。", nameof(page));
        lock (gate)
        {
            using var tx = db.BeginTransaction();
            // 检查与写入共用事务，不能只依赖网络返回后的检查；打开会话可能已抢先写入。
            if (Cursor("chat:" + chat) != 0) return false;
            if (reset) Execute("DELETE FROM records WHERE chat=$0 AND kind IN ('message','event','history')", chat);
            foreach (var x in page.Messages) Put("message", $"{chat}:{x.Seq}", x, x.Version, chat, x.Seq);
            foreach (var x in page.Events) Put("event", $"{chat}:{x.Id}", x, x.Version, chat, x.Time);
            SetCursor("chat:" + chat, page.ChatPts);
            // 首屏边界与游标必须一起提交，否则重启后可能把搜索缓存误认成连续历史。
            Put("history", chat.ToString(), page, page.ChatPts, chat);
            tx.Commit();
        }
        Changed?.Invoke();
        return true;
    }
    public void AcceptPending(OutboxEntry entry) => Atomic(() =>
    {
        Put("outbox", entry.ClientRandomId.ToString(), entry, entry.Pts, entry.ChatId);
        Execute("DELETE FROM records WHERE kind='pending' AND key=$0", entry.ClientRandomId.ToString());
    });
    private void ReconcilePending(OutboxEntry entry)
    {
        // Subscribe 或补差可以先于 RPC 回包确认；不能留下隐藏的 pending，重置缓存后再冒出来。
        // 同步确认只能收尾同一请求，异常 ID 冲突不能静默丢掉本地内容。
        if (entry.Pts <= 0 || entry.State is not (OutboxState.Pending or OutboxState.Sending or OutboxState.Sent or OutboxState.Failed)) return;
        using var command = db.CreateCommand();
        command.CommandText = "SELECT data FROM records WHERE kind='pending' AND key=$id";
        command.Parameters.AddWithValue("$id", entry.ClientRandomId.ToString());
        if (command.ExecuteScalar() is not byte[] bytes) return;
        var pending = SendMessageRequest.Parser.ParseFrom(bytes);
        if (pending.ChatId == entry.ChatId && pending.ReplyToSeq == entry.ReplyToSeq && pending.Segments.SequenceEqual(entry.Segments))
            Execute("DELETE FROM records WHERE kind='pending' AND key=$0", entry.ClientRandomId.ToString());
    }
    public void RemovePending(long id) => Atomic(() => Execute("DELETE FROM records WHERE kind='pending' AND key=$0", id.ToString()));
    public BetterChat.Application.ContactLists? ReadContacts()
    {
        lock (gate)
        {
            var friends = Read("contact_friends", ListFriendsResponse.Parser).SingleOrDefault();
            var groups = Read("contact_groups", ListGroupsResponse.Parser).SingleOrDefault();
            return friends is null || groups is null ? null : new(friends, groups);
        }
    }
    // 列表快照没有同步游标；两份列表共同提交，不能借列表请求推进 pts。
    public void SaveContacts(BetterChat.Application.ContactLists snapshot) => Atomic(() =>
    {
        Interlocked.Increment(ref contactsRevision);
        Put("contact_friends", "current", snapshot.Friends, 0);
        Put("contact_groups", "current", snapshot.Groups, 0);
    });
    public bool TrySaveContacts(BetterChat.Application.ContactLists snapshot, long revision)
    {
        lock (gate)
        {
            if (ContactsRevision != revision) return false;
            SaveContacts(snapshot); return true;
        }
    }
    public BetterChat.Application.ContactLists RemoveFriend(long userId)
    {
        lock (gate)
        {
            var snapshot = ReadContacts();
            if (snapshot is null)
            {
                var friends = new ListFriendsResponse(); var groups = new ListGroupsResponse();
                var peers = Peers;
                friends.Friends.AddRange(peers.Where(p => p.Kind == PeerKind.User && p.IsFriend));
                groups.Groups.AddRange(peers.Where(p => p.Kind == PeerKind.Group));
                snapshot = new(friends, groups);
            }
            for (int i = snapshot.Friends.Friends.Count - 1; i >= 0; i--)
                if (snapshot.Friends.Friends[i].PeerId == userId) snapshot.Friends.Friends.RemoveAt(i);
            foreach (var category in snapshot.Friends.Categories)
                while (category.UserIds.Remove(userId)) { }
            SaveContacts(snapshot); return snapshot;
        }
    }
    public void Reset() => Atomic(() =>
    {
        Execute("DELETE FROM records WHERE kind NOT IN ('pending','local_draft'); DELETE FROM cursors;");
        Interlocked.Increment(ref contactsRevision);
    }, dialogsChanged: true, peersChanged: true);
    public void Dispose() { lock (gate) db.Dispose(); }
}
