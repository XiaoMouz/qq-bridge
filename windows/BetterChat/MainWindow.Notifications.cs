using BetterChat.Application;
using BetterChat.Application.ViewModels;
using BetterChat.Infrastructure;
using Microsoft.UI.Xaml;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private WindowsNotifications? notifications;
    private string? notificationSession;

    private void InitializeNotifications()
    {
        notifications = new();
        notifications.Activated += (session, chat, sequence) => DispatcherQueue.TryEnqueue(async () =>
        {
            // 旧账号或上一次运行留下的通知不能打开当前账号的同号会话。
            if (session != notificationSession || runtime is null) return;
            Activate();
            await Guard(() => GoRoot(ChatKey(chat), () => OpenChat(chat, sequence)));
        });
        Closed += (_, _) => notifications.Dispose();
    }

    private void AttachNotifications(ClientSessionRuntime session)
    {
        string identity = Guid.NewGuid().ToString("N");
        notificationSession = identity;
        var policy = new MessageNotificationPolicy(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        session.StreamMessageReceived += message => DispatcherQueue.TryEnqueue(async () =>
        {
            if (runtime != session || notificationSession != identity) return;
            await Guard(async () =>
            {
                // 从仓储读取最新免打扰与已读状态，避免列表投影尚未刷新时误提醒。
                var dialog = await session.Repository.GetDialogAsync(message.ChatId, lifetime.Token);
                if (runtime != session || notificationSession != identity) return;
                if (dialog is null) return;
                string title = session.Dialogs.Items.FirstOrDefault(d => d.ChatId == message.ChatId)?.Title ?? dialog.PeerId.ToString();
                var result = policy.Evaluate(message, dialog, title, session.OwnUsers,
                    windowActive && ChatPanel.Visibility == Visibility.Visible ? selectedChat : null,
                    DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                if (result is not null) notifications?.Show(identity, result);
            });
        });
    }

    private async Task ClearNotifications()
    {
        var identity = notificationSession;
        notificationSession = null;
        if (identity is not null && notifications is not null) await notifications.ClearAsync(identity);
    }
}
