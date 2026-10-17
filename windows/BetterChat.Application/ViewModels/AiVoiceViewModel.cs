using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed class AiVoiceViewModel : IAsyncDisposable
{
    private readonly long chat;
    public RpcOperationViewModel<ListAiVoicesRequest, ListAiVoicesResponse> Load { get; }
    public RpcOperationViewModel<SendAiVoiceRequest, SendAiVoiceResponse> Send { get; }
    public AiVoiceViewModel(long chat,
        Func<ListAiVoicesRequest, CancellationToken, Task<ListAiVoicesResponse>> load,
        Func<SendAiVoiceRequest, CancellationToken, Task<SendAiVoiceResponse>> send, IUiDispatcher dispatcher)
    {
        this.chat = chat; Load = new(load, dispatcher, false); Send = new(send, dispatcher, true);
    }
    public Task<bool> LoadAsync(CancellationToken ct = default) => Load.ExecuteAsync(new() { ChatId = chat }, ct);
    public Task<bool> SendAsync(string voiceId, string text, CancellationToken ct = default)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } catalog
            || !catalog.Categories.Any(c => c.Voices.Any(v => v.Id == voiceId && v.Id.Length > 0)))
            throw new ArgumentException("请先加载并选择此群可用的语音角色。");
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("朗读内容不能为空。");
        return Send.ExecuteAsync(new() { ChatId = chat, VoiceId = voiceId, Text = text.Trim() }, ct);
    }
    public async ValueTask DisposeAsync()
    {
        Load.Dispose(); Send.Dispose();
        await Task.WhenAll(Load.WaitForIdleAsync(), Send.WaitForIdleAsync()).ConfigureAwait(false);
    }
}
