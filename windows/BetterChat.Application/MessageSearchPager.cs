using Qqbridge.V1;

namespace BetterChat.Core;

// 页面切换与重新搜索使旧请求失效，即使传输实现忽略取消也不能覆盖新结果。
public sealed class MessageSearchPager(Func<SearchMessagesRequest, CancellationToken, Task<SearchMessagesResponse>> fetch)
{
    private long generation;
    private readonly HashSet<(long Chat, long Seq)> seen = [];
    private readonly List<Message> results = [];
    private readonly HashSet<(long Time, long Chat, long Seq)> cursors = [];
    private bool exhausted;
    public IReadOnlyList<Message> Results => results;
    public string Query { get; private set; } = "";
    public long ChatId { get; private set; }
    public SearchCursor? Next { get; private set; }
    public bool Loading { get; private set; }

    public void Reset(string query, long chatId = 0)
    {
        generation++; Query = query.Trim(); ChatId = chatId;
        Next = null; Loading = false; exhausted = false; results.Clear(); seen.Clear(); cursors.Clear();
    }

    public async Task<bool> LoadAsync(CancellationToken ct)
    {
        if (Loading || Query.Length == 0 || exhausted) return false;
        long requestGeneration = generation;
        var request = new SearchMessagesRequest { Query = Query, ChatId = ChatId, Limit = 50 };
        if (Next is not null) request.Before = Next.Clone();
        Loading = true;
        try
        {
            var response = await fetch(request, ct);
            ct.ThrowIfCancellationRequested();
            if (requestGeneration != generation) return false;
            foreach (var m in response.Messages)
                if (seen.Add((m.ChatId, m.Seq))) results.Add(m.Clone());
            // 空页或原地游标不能形成无限翻页；失败时则保留原来的游标供重试。
            Next = response.Messages.Count > 0 && response.Next is not null
                && cursors.Add((response.Next.Time, response.Next.ChatId, response.Next.Seq))
                ? response.Next.Clone() : null;
            exhausted = Next is null;
            return true;
        }
        finally { if (requestGeneration == generation) Loading = false; }
    }
}
