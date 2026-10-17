using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record VoiceSendAction;
public sealed class VoiceMessageSendViewModel : IAsyncDisposable
{
    private readonly byte[] audio;
    public RpcOperationViewModel<VoiceSendAction, SendMessageResponse> Send { get; }
    public VoiceMessageSendViewModel(long chat, long randomId, RecordedVoice recording,
        Func<Stream, string, string, CancellationToken, Task<OutgoingMedia>> upload,
        Func<SendMessageRequest, CancellationToken, Task<SendMessageResponse>> send, IUiDispatcher dispatcher)
    {
        if (chat is <= 0 or > 9007199254740991 || randomId is <= 0 or > 9007199254740991
            || recording.Audio.Length is 0 or > 8388608 || recording.Duration < TimeSpan.FromSeconds(1))
            throw new ArgumentException("录音或发送目标无效。");
        audio = recording.Audio.ToArray();
        SendMessageRequest? request = null;
        SendMessageResponse? confirmed = null;
        Send = new(async (_, ct) =>
        {
            if (confirmed is not null) return confirmed.Clone();
            if (request is null)
            {
                using var source = new MemoryStream(audio, false);
                var media = (await upload(source, recording.Name, recording.Mime, ct).ConfigureAwait(false)).Clone();
                media.DurationSec = (uint)Math.Clamp(Math.Ceiling(recording.Duration.TotalSeconds), 1, 60);
                var prepared = new SendMessageRequest { ChatId = chat, ClientRandomId = randomId };
                prepared.Segments.Add(new OutgoingSegment { Record = media });
                OutgoingValidation.Validate(prepared);
                request = prepared;
            }
            ct.ThrowIfCancellationRequested();
            // 已上传媒体及请求快照在弹窗重试期间保留；网络超时不能改幂等 ID。
            var response = await send(request.Clone(), ct).ConfigureAwait(false);
            if (response.Entry is not { } entry || entry.ChatId != chat || entry.ClientRandomId != randomId)
                throw new IOException("语音发送确认不匹配，请检查同步结果后重试。");
            confirmed = response.Clone();
            return response;
        }, dispatcher, true);
    }
    public Task<bool> SendAsync(CancellationToken ct = default) => Send.ExecuteAsync(new(), ct);
    public async ValueTask DisposeAsync()
    {
        await Send.DisposeAsync(); Array.Clear(audio);
    }
}
