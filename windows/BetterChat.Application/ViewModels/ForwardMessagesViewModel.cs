using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed class ForwardMessagesViewModel : IAsyncDisposable
{
    public RpcOperationViewModel<ForwardMessagesRequest, ForwardMessagesResponse> Send { get; }
    public ForwardMessagesViewModel(Func<ForwardMessagesRequest, CancellationToken, Task<ForwardMessagesResponse>> forward, IUiDispatcher dispatcher)
    {
        Send = new(forward, dispatcher, true);
    }
    public Task<bool> SendAsync(ForwardMessagesRequest request, CancellationToken ct = default) =>
        Send.ExecuteAsync(ForwardValidation.Normalize(request), ct);
    public ValueTask DisposeAsync() => Send.DisposeAsync();
}
