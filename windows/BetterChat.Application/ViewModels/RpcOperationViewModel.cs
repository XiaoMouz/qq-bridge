using System.ComponentModel;
using System.Windows.Input;

namespace BetterChat.Application.ViewModels;

public interface IUiDispatcher { Task InvokeAsync(Action action); }

public sealed class SynchronizationContextDispatcher(SynchronizationContext context) : IUiDispatcher
{
    public Task InvokeAsync(Action action)
    {
        if (SynchronizationContext.Current == context) { action(); return Task.CompletedTask; }
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        context.Post(_ => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } }, null);
        return completion.Task;
    }
}

public enum OperationState { Idle, Running, Succeeded, Failed, Cancelled }

// 每个操作单飞。取消写请求不代表服务端撤销，UI 必须显式提示结果待确认，不能自动重发。
public sealed class RpcOperationViewModel<TRequest, TResponse>(
    Func<TRequest, CancellationToken, Task<TResponse>> execute, IUiDispatcher dispatcher, bool mutation) : INotifyPropertyChanged, ICommand, IDisposable, IAsyncDisposable
    where TRequest : class where TResponse : class
{
    private readonly object gate = new();
    private CancellationTokenSource? current;
    private int running;
    private volatile bool disposed;
    private Task draining = Task.CompletedTask;
    public OperationState State { get; private set; }
    public bool IsBusy => Volatile.Read(ref running) != 0;
    public TResponse? Result { get; private set; }
    public string? Error { get; private set; }
    public string? ErrorCode { get; private set; }
    public bool OutcomeUncertain { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !disposed && !IsBusy && parameter is TRequest;
    public async void Execute(object? parameter) { if (parameter is TRequest request) await ExecuteAsync(request); }
    private Task Publish(Action update) => dispatcher.InvokeAsync(() =>
    {
        if (disposed) return;
        update(); PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    });
    public async Task<bool> ExecuteAsync(TRequest request, CancellationToken ct = default)
    {
        CancellationTokenSource source;
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (gate)
        {
            if (disposed || running != 0) return false;
            source = CancellationTokenSource.CreateLinkedTokenSource(ct);
            current = source; Volatile.Write(ref running, 1);
            draining = draining.IsCompleted ? completed.Task : Task.WhenAll(draining, completed.Task);
        }
        bool dispatched = false;
        try
        {
            await Publish(() => { State = OperationState.Running; Error = ErrorCode = null; Result = null; OutcomeUncertain = false; }).ConfigureAwait(false);
            source.Token.ThrowIfCancellationRequested();
            dispatched = true;
            var response = await execute(request, source.Token).ConfigureAwait(false);
            source.Token.ThrowIfCancellationRequested();
            await Publish(() => { source.Token.ThrowIfCancellationRequested(); Result = response; State = OperationState.Succeeded; }).ConfigureAwait(false);
            return !disposed;
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested)
        {
            await Publish(() => { State = OperationState.Cancelled; OutcomeUncertain = mutation && dispatched; }).ConfigureAwait(false);
            return false;
        }
        catch (Exception error)
        {
            await Publish(() => { State = OperationState.Failed; Error = error.Message; ErrorCode = (error as BetterChat.Core.RpcException)?.Code; OutcomeUncertain = mutation && dispatched; }).ConfigureAwait(false);
            return false;
        }
        finally
        {
            lock (gate) { current = null; source.Dispose(); Volatile.Write(ref running, 0); }
            try { await Publish(() => { }).ConfigureAwait(false); }
            finally { completed.TrySetResult(); }
        }
    }
    public void Cancel() { lock (gate) current?.Cancel(); }
    public void Dispose() { lock (gate) { disposed = true; current?.Cancel(); } }
    public Task WaitForIdleAsync() { lock (gate) return draining; }
    public async ValueTask DisposeAsync() { Dispose(); await WaitForIdleAsync().ConfigureAwait(false); }
}
