using System.Text.RegularExpressions;

namespace BetterChat.Application;

// 主窗口的连接提示，和 iOS RootView 的 statusAccessory、DialogListView 的副标题对齐：
// 正在同步只在「消息」标题下写一行小字；横幅只留需要用户注意的：连不上服务器、要重新登录、QQ 掉线。
public sealed record ConnectionNotice(bool Syncing, string? Message, bool OffersQqLogin)
{
    public static readonly ConnectionNotice None = new(false, null, false);

    // status 是 SyncEngine.Status 发出的文字；qqOnline 为 null 表示还没查到（如服务器本身连不上）。
    public static ConnectionNotice Describe(string status, bool? qqOnline)
    {
        if (status == "正在连接…" || status.StartsWith("首屏预取失败", StringComparison.Ordinal)) return new(true, null, false);
        if (Regex.Match(status, @"^连接中断，(\d+) 秒后重试$") is { Success: true } retry)
            return new(false, $"连不上服务器，{retry.Groups[1].Value} 秒后重试", false);
        if (status.StartsWith("设备令牌已失效", StringComparison.Ordinal)) return new(false, "需要重新登录", false);
        if (status == "已连接" && qqOnline == false) return new(false, "QQ 已掉线，消息暂时收发不了", true);
        return None;
    }
}
