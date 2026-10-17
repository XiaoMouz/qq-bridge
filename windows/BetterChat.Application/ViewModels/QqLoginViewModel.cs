using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record QqLoginQuery;
public sealed record QqLoginSnapshot(GetQqLoginResponse State, long Revision);

// QQ 上游登录独立于 Bridge 密码登录；没有对应 Subscribe 事件时仅在页面存活期间查询。
public sealed class QqLoginViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly SemaphoreSlim serial = new(1);
    private readonly IUiDispatcher dispatcher;
    private readonly TimeSpan interval;
    private readonly CancellationTokenSource lifetime = new();
    private readonly CancellationToken lifetimeToken;
    private long revision, applied;
    private int observing;
    private int closed;
    private volatile bool disposed;
    private readonly Func<GetQqLoginRequest, CancellationToken, Task<GetQqLoginResponse>> getState;
    private readonly Func<RefreshQqLoginQrcodeRequest, CancellationToken, Task<RefreshQqLoginQrcodeResponse>> refreshCode;
    public GetQqLoginResponse? State { get; private set; }
    public RpcOperationViewModel<QqLoginQuery, QqLoginSnapshot> Load { get; }
    public RpcOperationViewModel<QqLoginQuery, QqLoginSnapshot> RefreshQr { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public QqLoginViewModel(IAdminService api, IUiDispatcher dispatcher, TimeSpan? pollInterval = null)
        : this(api.GetQqLoginAsync, api.RefreshQqLoginQrcodeAsync, dispatcher, pollInterval) { }

    public QqLoginViewModel(
        Func<GetQqLoginRequest, CancellationToken, Task<GetQqLoginResponse>> getState,
        Func<RefreshQqLoginQrcodeRequest, CancellationToken, Task<RefreshQqLoginQrcodeResponse>> refreshCode,
        IUiDispatcher dispatcher, TimeSpan? pollInterval = null)
    {
        this.getState = getState; this.refreshCode = refreshCode;
        this.dispatcher = dispatcher; interval = pollInterval ?? TimeSpan.FromSeconds(3); lifetimeToken = lifetime.Token;
        if (interval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(pollInterval));
        Load = new((_, ct) => QueryAsync(false, ct), dispatcher, false);
        RefreshQr = new((_, ct) => QueryAsync(true, ct), dispatcher, true);
        Load.PropertyChanged += Loaded; RefreshQr.PropertyChanged += Refreshed;
    }

    private async Task<QqLoginSnapshot> QueryAsync(bool refresh, CancellationToken ct)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            long current = Interlocked.Increment(ref revision);
            if (refresh)
            {
                await dispatcher.InvokeAsync(() =>
                {
                    if (disposed || ct.IsCancellationRequested) return;
                    // 刷新可能使旧二维码失效；失败时不能继续呈现它为有效二维码。
                    applied = current;
                    State = State?.Clone();
                    if (State is not null) State.QrcodeUrl = "";
                    PropertyChanged?.Invoke(this, new(nameof(State)));
                }).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                await refreshCode(new(), ct).ConfigureAwait(false);
            }
            ct.ThrowIfCancellationRequested();
            return new(await getState(new(), ct).ConfigureAwait(false), current);
        }
        finally { serial.Release(); }
    }
    private void Loaded(object? sender, PropertyChangedEventArgs args) => Publish(Load);
    private void Refreshed(object? sender, PropertyChangedEventArgs args) => Publish(RefreshQr);
    private void Publish(RpcOperationViewModel<QqLoginQuery, QqLoginSnapshot> operation)
    {
        if (disposed || operation.State != OperationState.Succeeded || operation.Result is not { } result || result.Revision < applied) return;
        applied = result.Revision; State = result.State.Clone();
        PropertyChanged?.Invoke(this, new(nameof(State)));
    }
    public async Task ObserveWhileVisibleAsync(CancellationToken ct)
    {
        if (disposed || Interlocked.CompareExchange(ref observing, 1, 0) != 0) return;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetimeToken);
        try
        {
            while (!linked.IsCancellationRequested)
            {
                await Load.ExecuteAsync(new(), linked.Token).ConfigureAwait(false);
                if (State?.LoggedIn == true || disposed || Load.ErrorCode is "unauthenticated" or "permission_denied") return;
                await Task.Delay(interval, linked.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested) { }
        finally { Interlocked.Exchange(ref observing, 0); }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0) return;
        disposed = true; lifetime.Cancel(); lifetime.Dispose();
        Load.PropertyChanged -= Loaded; RefreshQr.PropertyChanged -= Refreshed;
        Load.Dispose(); RefreshQr.Dispose();
    }
}
