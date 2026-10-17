using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record ChatStorageQuery(int TopLimit = 20);

// 服务端存储统计与本机缓存是不同概念；保留 uint64 和策略中的 -1/0，不在此推算可释放空间。
public sealed class ChatStorageViewModel : INotifyPropertyChanged, IDisposable
{
    public long ChatId { get; }
    public GetChatStorageResponse? Detail { get; private set; }
    public RpcOperationViewModel<ChatStorageQuery, GetChatStorageResponse> Load { get; }
    public event PropertyChangedEventHandler? PropertyChanged;
    private GetChatStorageResponse? applied;

    public ChatStorageViewModel(long chatId, IMediaService api, IUiDispatcher dispatcher)
        : this(chatId, api.GetChatStorageAsync, dispatcher) { }

    public ChatStorageViewModel(long chatId,
        Func<GetChatStorageRequest, CancellationToken, Task<GetChatStorageResponse>> load, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chatId);
        ChatId = chatId;
        Load = new(async (query, ct) =>
        {
            if (query.TopLimit is < 1 or > 100) throw new ArgumentOutOfRangeException(nameof(query.TopLimit), "最大内容列表条数须为 1 至 100。");
            var detail = await load(new() { ChatId = ChatId, TopLimit = query.TopLimit }, ct).ConfigureAwait(false);
            if (detail.Summary is null || detail.Summary.ChatId != ChatId)
                throw new IOException("存储详情返回的会话不匹配。");
            return detail;
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }
    public Task<bool> LoadAsync(int topLimit = 20, CancellationToken ct = default) => Load.ExecuteAsync(new(topLimit), ct);
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } result || ReferenceEquals(applied, result)) return;
        applied = result; Detail = result.Clone();
        PropertyChanged?.Invoke(this, new(nameof(Detail)));
    }
    public void Dispose() { Load.PropertyChanged -= Loaded; Load.Dispose(); }
}
