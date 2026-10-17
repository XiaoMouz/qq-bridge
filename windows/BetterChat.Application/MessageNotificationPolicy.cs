using Qqbridge.V1;

namespace BetterChat.Application;

public sealed record MessageNotification(long ChatId, long Sequence, string Title, string Body);

// 每个账号会话一个实例；只接收 Subscribe 消息，不把历史查询和补差当成新消息。
public sealed class MessageNotificationPolicy(long startedAt)
{
    private readonly HashSet<(long, long)> seen = [];
    private readonly Queue<(long, long)> order = [];
    public MessageNotification? Evaluate(Message message, Dialog dialog, string title, IReadOnlySet<long> ownUsers,
        long? foregroundChat, long now)
    {
        if (message.ChatId != dialog.ChatId || message.Seq <= 0 || message.State != MessageState.Normal
            || message.Time <= startedAt || now - message.Time > 600 || message.Time > now + 60) return null;
        var key = (message.ChatId, message.Seq);
        if (!seen.Add(key)) return null;
        order.Enqueue(key);
        if (order.Count > 2048) seen.Remove(order.Dequeue());
        if (ownUsers.Contains(message.SenderId) || foregroundChat == message.ChatId || message.Seq <= dialog.ReadInboxMaxSeq) return null;
        bool mentioned = (message.Flags & (32u | 256u)) != 0 || ((message.Flags & 64u) != 0 && dialog.MentionAllNotify);
        if (dialog.NotifyPolicy is "muted" or "archived" || (dialog.NotifyPolicy == "mentions" && !mentioned)) return null;
        if (dialog.NotifyPolicy is not ("" or "default" or "all" or "mentions")) return null;
        string body = string.IsNullOrWhiteSpace(message.Text) ? "新消息" : message.Text.Replace('\r', ' ').Replace('\n', ' ');
        if (body.Length > 160) body = body[..160] + "…";
        if (dialog.Scene == Scene.Group && !string.IsNullOrWhiteSpace(message.SenderName)) body = message.SenderName + "：" + body;
        return new(message.ChatId, message.Seq, title, body);
    }
}
