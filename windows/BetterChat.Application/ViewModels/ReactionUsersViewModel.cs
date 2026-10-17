using System.ComponentModel;
using System.Globalization;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record ReactionUsersQuery;
public sealed record ReactionParticipant(long UserId, string DisplayName);
public sealed record ReactionParticipants(IReadOnlyList<ReactionParticipant> Users);

// 每个实例绑定一个消息和表情，避免切换表情后旧请求覆盖另一份名单。
public sealed class ReactionUsersViewModel : INotifyPropertyChanged, IDisposable
{
    public long ChatId { get; }
    public long Sequence { get; }
    public string EmojiId { get; }
    public IReadOnlyList<ReactionParticipant> Users { get; private set; } = [];
    public RpcOperationViewModel<ReactionUsersQuery, ReactionParticipants> Load { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public ReactionUsersViewModel(long chatId, long sequence, string emojiId, IMessageService api, IUiDispatcher dispatcher)
        : this(chatId, sequence, emojiId, api.ListReactionUsersAsync, dispatcher) { }

    public ReactionUsersViewModel(long chatId, long sequence, string emojiId,
        Func<ListReactionUsersRequest, CancellationToken, Task<ListReactionUsersResponse>> load, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chatId);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(sequence);
        ArgumentException.ThrowIfNullOrWhiteSpace(emojiId);
        ChatId = chatId; Sequence = sequence; EmojiId = emojiId;
        Load = new(async (_, ct) =>
        {
            var response = await load(new() { ChatId = ChatId, Seq = Sequence, EmojiId = EmojiId }, ct).ConfigureAwait(false);
            var users = response.Users.GroupBy(u => u.UserId).Select(group =>
            {
                string name = group.Select(u => u.Name).FirstOrDefault(n => !string.IsNullOrWhiteSpace(n)) ?? group.Key.ToString(CultureInfo.InvariantCulture);
                return new ReactionParticipant(group.Key, name);
            }).ToArray();
            return new ReactionParticipants(users);
        }, dispatcher, false);
        Load.PropertyChanged += Loaded;
    }

    public Task<bool> LoadAsync(CancellationToken ct = default) => Load.ExecuteAsync(new(), ct);
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (Load.State != OperationState.Succeeded || Load.Result is not { } result || ReferenceEquals(Users, result.Users)) return;
        Users = result.Users;
        PropertyChanged?.Invoke(this, new(nameof(Users)));
    }
    public void Dispose() { Load.PropertyChanged -= Loaded; Load.Dispose(); }
}
