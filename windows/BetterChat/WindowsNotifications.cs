using BetterChat.Application;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace BetterChat;

internal sealed class WindowsNotifications : IDisposable
{
    public event Action<string, long, long>? Activated;
    public string? Error { get; private set; }
    private bool registered;
    public WindowsNotifications()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += Invoked;
            AppNotificationManager.Default.Register(); registered = true;
        }
        catch (Exception error)
        {
            Error = error.Message;
            AppNotificationManager.Default.NotificationInvoked -= Invoked;
        }
    }
    public void Show(string session, MessageNotification message)
    {
        if (!registered) return;
        try
        {
            var notification = new AppNotificationBuilder().AddArgument("session", session)
                .AddArgument("chat", message.ChatId.ToString()).AddArgument("seq", message.Sequence.ToString())
                .AddText(message.Title).AddText(message.Body).BuildNotification();
            notification.Group = session; notification.Tag = $"{message.ChatId}:{message.Sequence}";
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception error) { Error = error.Message; }
    }
    private void Invoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        var values = args.Arguments;
        if (values.TryGetValue("session", out var session) && values.TryGetValue("chat", out var chat)
            && values.TryGetValue("seq", out var seq) && long.TryParse(chat, out long chatId) && chatId > 0
            && long.TryParse(seq, out long sequence) && sequence > 0) Activated?.Invoke(session, chatId, sequence);
    }
    public async Task ClearAsync(string session)
    {
        if (!registered) return;
        try { await AppNotificationManager.Default.RemoveByGroupAsync(session); }
        catch (Exception error) { Error = error.Message; }
    }
    public void Dispose()
    {
        AppNotificationManager.Default.NotificationInvoked -= Invoked;
        if (registered)
        {
            try { AppNotificationManager.Default.Unregister(); }
            catch (Exception error) { Error = error.Message; }
            registered = false;
        }
    }
}
