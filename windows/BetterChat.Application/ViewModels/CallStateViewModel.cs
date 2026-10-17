using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record ActiveCallQuery;
public sealed record ActiveCallSnapshot(GetActiveCallResponse Response, long EventRevision);

// 通话临时事件不写 pts。终态不可被迟到的响铃/接通或恢复请求覆盖。
public sealed class CallStateViewModel : INotifyPropertyChanged, IDisposable, IAsyncDisposable
{
    private readonly IUiDispatcher dispatcher;
    private readonly HashSet<string> ended = new(StringComparer.Ordinal);
    private long eventRevision;
    private volatile bool disposed;
    private ActiveCallSnapshot? applied;
    public Call? Active { get; private set; }
    public Call? LastEnded { get; private set; }
    public RpcOperationViewModel<ActiveCallQuery, ActiveCallSnapshot> Restore { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public CallStateViewModel(ICallService api, IUiDispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        Restore = new(async (_, ct) =>
        {
            long revision = Interlocked.Read(ref eventRevision);
            return new(await api.GetActiveCallAsync(new(), ct).ConfigureAwait(false), revision);
        }, dispatcher, false);
        Restore.PropertyChanged += Restored;
    }

    public Task<bool> RestoreAsync(CancellationToken ct = default) => Restore.ExecuteAsync(new(), ct);
    public Task ApplyUpdateAsync(Call update)
    {
        var snapshot = update.Clone();
        return dispatcher.InvokeAsync(() =>
        {
            if (disposed || snapshot.Id.Length == 0) return;
            Interlocked.Increment(ref eventRevision);
            Apply(snapshot);
        });
    }
    private void Restored(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || Restore.State != OperationState.Succeeded || Restore.Result is not { } result || ReferenceEquals(applied, result)) return;
        applied = result;
        if (result.EventRevision != Interlocked.Read(ref eventRevision)) return;
        if (result.Response.Call is { } call) Apply(call.Clone());
        else { Active = null; Changed(); }
    }
    private void Apply(Call update)
    {
        if (update.Id.Length == 0) return;
        if (update.Phase == CallPhase.Ended)
        {
            ended.Add(update.Id);
            if (LastEnded is null || update.EndedAt >= LastEnded.EndedAt) LastEnded = update;
            if (Active?.Id == update.Id) Active = null;
            Changed(); return;
        }
        if (ended.Contains(update.Id)) return;
        if (Active is { } active)
        {
            if (active.Id == update.Id && Rank(update.Phase) < Rank(active.Phase)) return;
            if (active.Id != update.Id && update.InviteAt < active.InviteAt) return;
        }
        Active = update; Changed();
    }
    private static int Rank(CallPhase phase) => phase switch
    {
        CallPhase.Ringing => 1, CallPhase.Accepting => 2, CallPhase.Connected => 3, CallPhase.Ended => 4, _ => 0
    };
    private void Changed() => PropertyChanged?.Invoke(this, new(null));
    public void Dispose() { disposed = true; Restore.PropertyChanged -= Restored; Restore.Dispose(); }
    public async ValueTask DisposeAsync() { Dispose(); await Restore.WaitForIdleAsync().ConfigureAwait(false); }
}
