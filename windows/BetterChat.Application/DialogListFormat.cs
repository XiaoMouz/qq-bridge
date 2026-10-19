using System.Globalization;
using Qqbridge.V1;

namespace BetterChat.Application;

// 会话行的文字规则，和 iOS DialogListView 的 Format.listTime、Badges、DialogActions 对齐，放在这里便于测试。
public static class DialogListFormat
{
    private static readonly CultureInfo Chinese = CultureInfo.GetCultureInfo("zh-CN");

    // 今天显示时刻，昨天显示「昨天」，一周内显示星期，再早显示 yy/MM/dd。
    public static string ListTime(long unix, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (unix <= 0) return "";
        var time = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeSeconds(unix), zone);
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        int days = (today - time.Date).Days;
        if (days <= 0) return time.ToString("HH:mm", Chinese);
        if (days == 1) return "昨天";
        if (days < 7) return Chinese.DateTimeFormat.GetDayName(time.DayOfWeek);
        return time.ToString("yy/MM/dd", Chinese);
    }

    // 有的昵称只由不可见字符组成（2026-10-19 好友列表实测有一个只含 U+2062），显示出来是空白行，
    // 这类名字按空处理、改用备注或号码。
    public static bool HasVisibleText(string? text) => !string.IsNullOrEmpty(text) && text.Any(c =>
        !char.IsWhiteSpace(c) && char.GetUnicodeCategory(c) is not (UnicodeCategory.Format or UnicodeCategory.Control)
        && c is not ('\u3164' or '\u115F' or '\u1160' or '\uFFA0' or '\u2800'));

    public static string UnreadText(uint count) => count == 0 ? "" : count > 99 ? "99+" : count.ToString(CultureInfo.InvariantCulture);

    public static bool IsMuted(Dialog dialog) => dialog.NotifyPolicy is "muted" or "archived";
    public static bool IsArchived(Dialog dialog) => dialog.NotifyPolicy == "archived";

    // 「接收不提醒」和「接收并提醒」来回切；取消免打扰时群回到 all、私聊回到 default（与 iOS 一致）。
    public static string ToggleMutedPolicy(Dialog dialog) =>
        IsMuted(dialog) ? (dialog.Scene == Scene.Group ? "all" : "default") : "muted";

    // 移出群助手后仍保持免打扰，只是不再折叠。
    public static string ToggleArchivedPolicy(Dialog dialog) => IsArchived(dialog) ? "muted" : "archived";

    // 两行预览里「发送者：」前缀：自己发的是「我」，群里是群名片 / 昵称；私聊别人发的不加。名字过长截到 10 个字。
    public static string SenderPrefix(Dialog dialog, IReadOnlySet<long> ownUsers)
    {
        var m = dialog.TopMessage;
        if (m is null || m.Seq <= 0 || m.Kind != MessageKind.Normal || dialog.Draft is { Segments.Count: > 0 }) return "";
        if (ownUsers.Contains(m.SenderId)) return "我：";
        if (dialog.Scene != Scene.Group) return "";
        string name = m.SenderName.Length > 0 ? m.SenderName : m.SenderId.ToString(CultureInfo.InvariantCulture);
        return (name.Length > 10 ? name[..10] + "…" : name) + "：";
    }
}
