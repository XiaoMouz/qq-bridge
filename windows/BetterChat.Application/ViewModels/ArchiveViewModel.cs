using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed class ArchiveViewModel : IDisposable, IAsyncDisposable
{
    public RpcOperationViewModel<ListArchiveStatusRequest, ListArchiveStatusResponse> Load { get; }
    public RpcOperationViewModel<SetDeepArchiveRequest, SetDeepArchiveResponse> SetDeepArchive { get; }
    public RpcOperationViewModel<FillHolesNowRequest, FillHolesNowResponse> FillHoles { get; }
    public ArchiveViewModel(
        Func<ListArchiveStatusRequest, CancellationToken, Task<ListArchiveStatusResponse>> load,
        Func<SetDeepArchiveRequest, CancellationToken, Task<SetDeepArchiveResponse>> set,
        Func<FillHolesNowRequest, CancellationToken, Task<FillHolesNowResponse>> fill, IUiDispatcher dispatcher)
    {
        Load = new(load, dispatcher, false);
        SetDeepArchive = new((request, ct) =>
        {
            if (request.ChatId is <= 0 or > 9007199254740991) throw new ArgumentException("归档会话标识无效。");
            return set(request.Clone(), ct);
        }, dispatcher, true);
        FillHoles = new(fill, dispatcher, true);
    }
    public void Dispose() { Load.Dispose(); SetDeepArchive.Dispose(); FillHoles.Dispose(); }
    public async ValueTask DisposeAsync()
    {
        Dispose(); await Task.WhenAll(Load.WaitForIdleAsync(), SetDeepArchive.WaitForIdleAsync(), FillHoles.WaitForIdleAsync()).ConfigureAwait(false);
    }
}
