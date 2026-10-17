using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

// 操作固定到创建时的消息；窗口切换选择不能改变在途请求的目标。
public sealed class MessageActionsViewModel : IAsyncDisposable
{
    private readonly long chat, seq;
    public RpcOperationViewModel<RecallMessageRequest, RecallMessageResponse> Recall { get; }
    public RpcOperationViewModel<ReactRequest, ReactResponse> React { get; }
    public MessageActionsViewModel(long chat, long seq,
        Func<RecallMessageRequest, CancellationToken, Task<RecallMessageResponse>> recall,
        Func<ReactRequest, CancellationToken, Task<ReactResponse>> react, IUiDispatcher dispatcher)
    {
        this.chat = chat; this.seq = seq;
        Recall = new(recall, dispatcher, true); React = new(react, dispatcher, true);
    }
    public Task<bool> RecallAsync(CancellationToken ct = default) => Recall.ExecuteAsync(new() { ChatId = chat, Seq = seq }, ct);
    public Task<bool> ReactAsync(string emojiId, bool add, CancellationToken ct = default) =>
        React.ExecuteAsync(new() { ChatId = chat, Seq = seq, EmojiId = emojiId, Add = add }, ct);
    public async ValueTask DisposeAsync()
    {
        Recall.Dispose(); React.Dispose();
        await Task.WhenAll(Recall.WaitForIdleAsync(), React.WaitForIdleAsync()).ConfigureAwait(false);
    }
}
