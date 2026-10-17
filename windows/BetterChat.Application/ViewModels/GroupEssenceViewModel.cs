using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

// 由 UI 调度器调用；事件先排队，读取期间到达的下一次事件在本次结束后再处理。
public sealed class GroupEssenceViewModel : IDisposable
{
    private readonly HashSet<(long Chat, long Seq)> dirty = [];
    private readonly List<GroupEssence> items = [];
    private bool initialized, draining, disposed;
    public IReadOnlyList<GroupEssence> Items => items;
    public string? RefreshError { get; private set; }
    public event Action? Changed;
    public RpcOperationViewModel<ListGroupEssenceRequest, ListGroupEssenceResponse> Load { get; }
    public RpcOperationViewModel<GetHistoryRequest, GetHistoryResponse> Refresh { get; }

    public GroupEssenceViewModel(
        Func<ListGroupEssenceRequest, CancellationToken, Task<ListGroupEssenceResponse>> list,
        Func<GetHistoryRequest, CancellationToken, Task<GetHistoryResponse>> history, IUiDispatcher dispatcher)
    {
        Load = new(list, dispatcher, false); Refresh = new(history, dispatcher, false);
    }
    public async Task<bool> LoadAsync(long groupId, CancellationToken ct)
    {
        if (!await Load.ExecuteAsync(new() { GroupId = groupId }, ct) || disposed) return false;
        items.Clear(); items.AddRange(Load.Result!.Items.Select(i => i.Clone())); initialized = true;
        Changed?.Invoke();
        await DrainAsync(ct);
        return !disposed && !ct.IsCancellationRequested;
    }
    public async Task MediaReadyAsync(MediaReadyUpdate update, CancellationToken ct)
    {
        if (disposed || update.ChatId <= 0 || update.Seq <= 0) return;
        var key = (update.ChatId, update.Seq);
        if (initialized && !items.Any(i => i.Message?.ChatId == key.ChatId && i.Message.Seq == key.Seq)) return;
        // 初次加载期间也保留事件，避免“响应快照已取出但页面尚未显示”窗口丢失通知。
        if (dirty.Count < 512) dirty.Add(key);
        await DrainAsync(ct);
    }
    private async Task DrainAsync(CancellationToken ct)
    {
        if (!initialized || draining || disposed) return;
        draining = true;
        try
        {
            while (!disposed && !ct.IsCancellationRequested && dirty.Count > 0)
            {
                var key = dirty.First(); dirty.Remove(key);
                int index = items.FindIndex(i => i.Message?.ChatId == key.Chat && i.Message.Seq == key.Seq);
                if (index < 0) continue;
                bool success = await Refresh.ExecuteAsync(new() { ChatId = key.Chat, AnchorSeq = key.Seq, Direction = HistoryDirection.Around, Limit = 1 }, ct);
                if (disposed || ct.IsCancellationRequested) return;
                if (!success) { RefreshError = Refresh.Error ?? "媒体状态更新失败，请刷新精华列表。"; Changed?.Invoke(); continue; }
                RefreshError = null;
                var message = Refresh.Result!.Messages.FirstOrDefault(m => m.ChatId == key.Chat && m.Seq == key.Seq);
                if (message is null || message.Version < items[index].Message.Version) continue;
                items[index].Message = message.Clone(); Changed?.Invoke();
            }
        }
        finally { draining = false; }
    }
    public void Dispose() { disposed = true; dirty.Clear(); Load.Dispose(); Refresh.Dispose(); Changed = null; }
}
