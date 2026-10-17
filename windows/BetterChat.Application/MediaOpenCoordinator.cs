using System.Threading.Channels;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application;

// 必须先挂接 Notify 再调用 ResolveAsync，保留 RPC 返回前先到达的就绪事件。
public sealed class MediaOpenCoordinator(long chat, long sequence, MediaInfo initial,
    Func<RequestMediaRequest, CancellationToken, Task<RequestMediaResponse>> request)
{
    private readonly MediaInfo snapshot = initial.Clone();
    private readonly Channel<MediaReadyUpdate> events = Channel.CreateBounded<MediaReadyUpdate>(new BoundedChannelOptions(1)
    { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true, AllowSynchronousContinuations = false });

    public void Notify(MediaReadyUpdate update)
    {
        if (update.ChatId == chat && update.Seq == sequence && update.Ord == snapshot.Ord
            && !update.Thumb && update.Node < 0 && update.ForwardPath.Length == 0)
            events.Writer.TryWrite(update.Clone());
    }
    public async Task<MediaInfo> ResolveAsync(CancellationToken ct, TimeSpan? timeout = null)
    {
        if (chat <= 0 || sequence <= 0) throw new ArgumentException("媒体消息标识无效。");
        ct.ThrowIfCancellationRequested();
        if (snapshot.State == MediaState.Stored && MediaPresentation.OpenHash(snapshot).Length > 0) return snapshot.Clone();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout ?? TimeSpan.FromMinutes(5));
        try
        {
            for (int attempt = 0; attempt < 6; attempt++)
            {
                var query = new RequestMediaRequest { Original = true };
                query.Refs.Add(new MediaRef { ChatId = chat, Seq = sequence, Ord = snapshot.Ord });
                var response = await request(query, deadline.Token).ConfigureAwait(false);
                deadline.Token.ThrowIfCancellationRequested();
                var media = response.Media.FirstOrDefault()?.Clone() ?? throw new IOException("服务器未返回媒体状态。");
                if (media.State is MediaState.Stored or MediaState.Failed or MediaState.Expired or MediaState.Skipped or MediaState.Purged) return media;
                var ready = await events.Reader.ReadAsync(deadline.Token).ConfigureAwait(false);
                if (ready.State is "failed" or "expired" or "skipped")
                {
                    media.State = ready.State switch { "expired" => MediaState.Expired, "skipped" => MediaState.Skipped, _ => MediaState.Failed };
                    return media;
                }
                // 不信任事件中的哈希作为完整媒体信息，收到就绪后重读可播放变体和 MIME。
            }
            throw new IOException("媒体状态尚未稳定，请重试。");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested && deadline.IsCancellationRequested)
        { throw new TimeoutException("等待媒体下载超时，请重试。"); }
    }
}
