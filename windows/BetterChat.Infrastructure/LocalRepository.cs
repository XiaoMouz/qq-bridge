using System.Threading.Channels;
using BetterChat.Application;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Infrastructure;

// 单个后台消费者与有界队列防止频繁刷新堆积线程；关闭时先收尾，再释放自有存储。
public sealed class LocalRepository : IChatReadRepository, IContactDirectoryCache, IAsyncDisposable
{
    private readonly ILocalStore store;
    private readonly bool ownsStore;
    private readonly Channel<Work> queue;
    private readonly Task worker;

    public LocalRepository(ILocalStore store, bool ownsStore = false, int capacity = 32)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(capacity);
        this.store = store; this.ownsStore = ownsStore;
        queue = Channel.CreateBounded<Work>(new BoundedChannelOptions(capacity)
        {
            SingleReader = true, SingleWriter = false, FullMode = BoundedChannelFullMode.Wait,
            AllowSynchronousContinuations = false
        });
        worker = Task.Run(ConsumeAsync);
    }

    private async Task ConsumeAsync()
    {
        try
        {
            await foreach (var work in queue.Reader.ReadAllAsync().ConfigureAwait(false)) work.Run();
        }
        finally { if (ownsStore) store.Dispose(); }
    }

    private async Task<T> ExecuteAsync<T>(Func<T> execute, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var work = new StoreWork<T>(execute, ct);
        try { await queue.Writer.WriteAsync(work, ct).ConfigureAwait(false); }
        catch (ChannelClosedException) { throw new ObjectDisposedException(nameof(LocalRepository)); }
        return await work.Completion.Task.ConfigureAwait(false);
    }

    public Task<IReadOnlyList<Dialog>> GetDialogsAsync(CancellationToken ct = default) =>
        ExecuteAsync<IReadOnlyList<Dialog>>(() => store.Dialogs, ct);
    public Task<Dialog?> GetDialogAsync(long chat, CancellationToken ct = default) =>
        ExecuteAsync(() => store.ReadDialog(chat), ct);
    public Task<DialogDirectorySnapshot> GetDialogDirectoryAsync(CancellationToken ct = default, long knownPeerRevision = -1) =>
        ExecuteAsync(() => store.ReadDialogDirectory(knownPeerRevision), ct);
    public Task<TimelineSnapshot> GetTimelineAsync(TimelineQuery query, CancellationToken ct = default)
    {
        var copy = query with { Sequences = query.Sequences.ToArray(), EventIds = query.EventIds.ToArray() };
        return ExecuteAsync(() => store.ReadTimeline(copy), ct);
    }
    public Task<GetHistoryResponse?> GetLatestHistoryAsync(long chat, CancellationToken ct = default) =>
        ExecuteAsync(() => store.LatestHistory(chat), ct);
    public Task<SaveDraftRequest?> GetLocalDraftAsync(long chat, CancellationToken ct = default) => ExecuteAsync(() => store.ReadLocalDraft(chat), ct);
    public Task SaveLocalDraftAsync(SaveDraftRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return ExecuteAsync(() => { store.SaveLocalDraft(copy); return true; }, ct);
    }
    public Task ConfirmLocalDraftAsync(long chat, CancellationToken ct = default) =>
        ExecuteAsync(() => { store.ConfirmLocalDraft(chat); return true; }, ct);
    public Task SavePendingAsync(SendMessageRequest request, CancellationToken ct = default)
    {
        var copy = request.Clone();
        return ExecuteAsync(() => { store.SavePending(copy); return true; }, ct);
    }
    public Task AcceptPendingAsync(OutboxEntry entry, CancellationToken ct = default)
    {
        var copy = entry.Clone();
        return ExecuteAsync(() => { store.AcceptPending(copy); return true; }, ct);
    }
    public Task MergeHistoryPageAsync(long chat, GetHistoryResponse page, bool latest, CancellationToken ct = default)
    {
        var copy = page.Clone();
        return ExecuteAsync(() => { store.MergeHistoryPage(chat, copy, latest); return true; }, ct);
    }
    public Task<IReadOnlyList<Peer>> GetPeersAsync(CancellationToken ct = default) =>
        ExecuteAsync<IReadOnlyList<Peer>>(() => store.Peers, ct);
    public Task<ContactLists?> ReadContactsAsync(CancellationToken ct = default) =>
        ExecuteAsync(store.ReadContacts, ct);
    public Task<long> GetContactsRevisionAsync(CancellationToken ct = default) => ExecuteAsync(() => store.ContactsRevision, ct);
    public Task<bool> TrySaveContactsAsync(ContactLists snapshot, long revision, CancellationToken ct = default)
    {
        var copy = new ContactLists(snapshot.Friends.Clone(), snapshot.Groups.Clone());
        return ExecuteAsync(() => store.TrySaveContacts(copy, revision), ct);
    }
    public Task<ContactLists> RemoveFriendAsync(long userId, CancellationToken ct = default) => ExecuteAsync(() => store.RemoveFriend(userId), ct);
    public Task SaveContactsAsync(ContactLists snapshot, CancellationToken ct = default)
    {
        // 调用方可以继续编辑其对象，队列必须持有独立的整份快照。
        var copy = new ContactLists(snapshot.Friends.Clone(), snapshot.Groups.Clone());
        return ExecuteAsync(() => { store.SaveContacts(copy); return true; }, ct);
    }
    public Task<IReadOnlyList<Message>> GetMessagesAsync(long chatId, IEnumerable<long> sequences, long? newerThan, CancellationToken ct = default)
    {
        var keys = sequences.Select(seq => $"{chatId}:{seq}").ToArray();
        return ExecuteAsync<IReadOnlyList<Message>>(() => store.ReadWindow("message", Message.Parser, chatId, keys, newerThan), ct);
    }
    public Task<IReadOnlyList<ChatEvent>> GetEventsAsync(long chatId, IEnumerable<long> eventIds, long? newerThanTime, CancellationToken ct = default)
    {
        var keys = eventIds.Select(id => $"{chatId}:{id}").ToArray();
        return ExecuteAsync<IReadOnlyList<ChatEvent>>(() => store.ReadWindow("event", ChatEvent.Parser, chatId, keys, newerThanTime), ct);
    }

    public async ValueTask DisposeAsync()
    {
        queue.Writer.TryComplete();
        await worker.ConfigureAwait(false);
    }

    private abstract class Work { public abstract void Run(); }
    private sealed class StoreWork<T>(Func<T> execute, CancellationToken ct) : Work
    {
        public TaskCompletionSource<T> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override void Run()
        {
            if (ct.IsCancellationRequested) { Completion.TrySetCanceled(ct); return; }
            try
            {
                var result = execute();
                if (ct.IsCancellationRequested) Completion.TrySetCanceled(ct);
                else Completion.TrySetResult(result);
            }
            catch (Exception error) { Completion.TrySetException(error); }
        }
    }
}
