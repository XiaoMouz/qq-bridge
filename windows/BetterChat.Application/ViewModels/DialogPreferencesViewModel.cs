using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public enum NotificationPolicy { Default, All, Mentions, Muted, Archived }
public sealed record BooleanPreference(bool Value);
public sealed record NotificationPreference(NotificationPolicy Value);

// RPC 只返回 changed，没有 dialog_pts；确认状态仍以同步快照为准，不能伪造版本写回库。
public sealed class DialogPreferencesViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly IUiDispatcher dispatcher;
    private long dialogPts;
    private volatile bool disposed;
    public long ChatId { get; }
    public bool Pinned { get; private set; }
    public string NotifyPolicy { get; private set; }
    public bool MentionAllNotify { get; private set; }
    public RpcOperationViewModel<BooleanPreference, SetPinnedResponse> SetPinned { get; }
    public RpcOperationViewModel<NotificationPreference, SetNotifyPolicyResponse> SetPolicy { get; }
    public RpcOperationViewModel<BooleanPreference, SetMentionAllNotifyResponse> SetMentionAll { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public DialogPreferencesViewModel(Dialog dialog, IDialogService api, IUiDispatcher dispatcher)
        : this(dialog, api.SetPinnedAsync, api.SetNotifyPolicyAsync, api.SetMentionAllNotifyAsync, dispatcher) { }

    public DialogPreferencesViewModel(Dialog dialog,
        Func<SetPinnedRequest, CancellationToken, Task<SetPinnedResponse>> pinned,
        Func<SetNotifyPolicyRequest, CancellationToken, Task<SetNotifyPolicyResponse>> policy,
        Func<SetMentionAllNotifyRequest, CancellationToken, Task<SetMentionAllNotifyResponse>> mentionAll, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(dialog.ChatId);
        ChatId = dialog.ChatId; dialogPts = dialog.DialogPts; this.dispatcher = dispatcher;
        Pinned = dialog.Pinned; NotifyPolicy = dialog.NotifyPolicy; MentionAllNotify = dialog.MentionAllNotify;
        SetPinned = new((value, ct) => pinned(new() { ChatId = ChatId, Pinned = value.Value }, ct), dispatcher, true);
        SetPolicy = new((value, ct) => policy(new() { ChatId = ChatId, Policy = Encode(value.Value) }, ct), dispatcher, true);
        SetMentionAll = new((value, ct) => mentionAll(new() { ChatId = ChatId, Enabled = value.Value }, ct), dispatcher, true);
    }

    public Task ApplyDialogAsync(Dialog dialog)
    {
        long chat = dialog.ChatId, pts = dialog.DialogPts;
        bool pinned = dialog.Pinned, mentionAll = dialog.MentionAllNotify;
        string policy = dialog.NotifyPolicy;
        return dispatcher.InvokeAsync(() =>
        {
            if (disposed || chat != ChatId || pts <= dialogPts) return;
            dialogPts = pts; Pinned = pinned; NotifyPolicy = policy; MentionAllNotify = mentionAll;
            PropertyChanged?.Invoke(this, new(null));
        });
    }

    private static string Encode(NotificationPolicy policy) => policy switch
    {
        NotificationPolicy.Default => "default", NotificationPolicy.All => "all",
        NotificationPolicy.Mentions => "mentions", NotificationPolicy.Muted => "muted",
        NotificationPolicy.Archived => "archived", _ => throw new ArgumentOutOfRangeException(nameof(policy))
    };

    public void Dispose()
    {
        disposed = true; SetPinned.Dispose(); SetPolicy.Dispose(); SetMentionAll.Dispose();
    }
}
