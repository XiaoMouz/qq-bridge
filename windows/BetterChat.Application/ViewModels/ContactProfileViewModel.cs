using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record ProfileRefresh;
public sealed record ProfileOpen;
public sealed class ContactProfileViewModel : IDisposable, IAsyncDisposable
{
    public RpcOperationViewModel<ProfileRefresh, Peer> Refresh { get; }
    public RpcOperationViewModel<ProfileOpen, OpenChatResponse> Open { get; }
    public ContactProfileViewModel(Peer peer, long viaGroup,
        Func<GetUserProfileRequest, CancellationToken, Task<GetUserProfileResponse>> user,
        Func<GetGroupProfileRequest, CancellationToken, Task<GetGroupProfileResponse>> group,
        Func<OpenChatRequest, CancellationToken, Task<OpenChatResponse>> open, IUiDispatcher dispatcher)
    {
        long id = peer.PeerId; var kind = peer.Kind;
        if (id is <= 0 or > 9007199254740991 || viaGroup is < 0 or > 9007199254740991 || kind is not (PeerKind.User or PeerKind.Group))
            throw new ArgumentException("资料目标无效。");
        Refresh = new(async (_, ct) =>
        {
            var updated = kind == PeerKind.Group
                ? (await group(new() { GroupId = id, Refresh = true }, ct).ConfigureAwait(false)).Profile?.Peer
                : (await user(new() { UserId = id, Refresh = true }, ct).ConfigureAwait(false)).Profile?.Peer;
            if (updated is null || updated.PeerId != id || updated.Kind != kind) throw new IOException("资料响应与目标不匹配。");
            return updated.Clone();
        }, dispatcher, false);
        Open = new(async (_, ct) =>
        {
            var result = await open(new() { Scene = kind == PeerKind.Group ? Scene.Group : Scene.Friend, PeerId = id, ViaGroupId = viaGroup }, ct).ConfigureAwait(false);
            if (result.ChatId is <= 0 or > 9007199254740991) throw new IOException("打开会话返回无效标识。");
            return result;
        }, dispatcher, true);
    }
    public void Dispose() { Refresh.Dispose(); Open.Dispose(); }
    public async ValueTask DisposeAsync() { Dispose(); await Task.WhenAll(Refresh.WaitForIdleAsync(), Open.WaitForIdleAsync()).ConfigureAwait(false); }
}
