using System.ComponentModel;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed class GroupMembersViewModel : IDisposable
{
    private int offset;
    private readonly List<GroupMember> members = [];
    private readonly HashSet<long> seen = [];
    private ListGroupMembersResponse? applied;
    public IReadOnlyList<GroupMember> Members => members;
    public uint Total { get; private set; }
    public bool Stale { get; private set; }
    public bool HasMore { get; private set; } = true;
    public RpcOperationViewModel<object, ListGroupMembersResponse> Load { get; }

    public GroupMembersViewModel(long groupId,
        Func<ListGroupMembersRequest, CancellationToken, Task<ListGroupMembersResponse>> load, IUiDispatcher dispatcher)
    {
        if (groupId is <= 0 or > 9007199254740991) throw new ArgumentOutOfRangeException(nameof(groupId));
        Load = new(async (_, ct) =>
        {
            var response = await load(new() { GroupId = groupId, Offset = offset, Limit = 100 }, ct).ConfigureAwait(false);
            if (response.Members.Any(m => m.UserId is <= 0 or > 9007199254740991)) throw new IOException("成员列表包含无效用户标识。");
            _ = checked(offset + response.Members.Count);
            return response.Clone();
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }
    public Task<bool> LoadMoreAsync(CancellationToken ct = default) => HasMore ? Load.ExecuteAsync(new(), ct) : Task.FromResult(false);
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } page || ReferenceEquals(applied, page)) return;
        applied = page;
        // 群成员可能在翻页期间变化；偏移按原始页长推进，显示按用户去重。
        offset += page.Members.Count;
        foreach (var member in page.Members) if (seen.Add(member.UserId)) members.Add(member.Clone());
        Total = page.Total; Stale = page.Stale;
        HasMore = page.Members.Count > 0 && offset < (long)Total;
    }
    public void Dispose() { Load.PropertyChanged -= Loaded; Load.Dispose(); }
}
