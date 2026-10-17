using BetterChat.Application.ViewModels;
using Microsoft.UI.Dispatching;

namespace BetterChat;

internal sealed class UiDispatcher(DispatcherQueue queue) : IUiDispatcher
{
    public Task InvokeAsync(Action action)
    {
        if (queue.HasThreadAccess) { action(); return Task.CompletedTask; }
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() =>
        {
            try { action(); completion.TrySetResult(); }
            catch (Exception error) { completion.TrySetException(error); }
        })) completion.TrySetException(new ObjectDisposedException(nameof(DispatcherQueue)));
        return completion.Task;
    }
}
