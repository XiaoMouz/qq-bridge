using System.Globalization;

namespace BetterChat.Application;

// Windows 版自动更新的状态和文字（下载、替换由 Velopack 做，见 BetterChat/AppUpdater.cs）。
// 和 iOS AppUpdate 一样不弹窗：后台查、后台下好，「设置」上一个小圆点（进过一次「关于」就消失），关于页里写明新版本，
// 点「重启并更新」立即换；不点的话下次退出时安静地换上。
public enum UpdatePhase { Unavailable, Idle, Checking, Downloading, Ready, Failed }

public sealed record AppUpdateState(UpdatePhase Phase, string? Version = null, int Progress = 0, DateTimeOffset? LastCheck = null, string? Notes = null)
{
    public static readonly TimeSpan Interval = TimeSpan.FromHours(6);
    private static readonly CultureInfo Chinese = CultureInfo.GetCultureInfo("zh-CN");

    // 启动和窗口回到前台时，距上次检查超过 6 小时才再查（同 iOS）。
    public static bool IsDue(DateTimeOffset? lastCheck, DateTimeOffset now) => lastCheck is null || now - lastCheck.Value >= Interval;

    // 「设置」上的圆点：有下好的新版本，且还没在「关于」里看过这个版本。
    public bool ShowsBadge(string? seenVersion) => Phase == UpdatePhase.Ready && Version is not null && Version != seenVersion;

    public bool CanCheck => Phase is UpdatePhase.Idle or UpdatePhase.Failed;

    public string Description(DateTimeOffset now) => Phase switch
    {
        UpdatePhase.Unavailable => "本机构建不自动更新；安装版会在后台检查新版本",
        UpdatePhase.Checking => "正在检查新版本…",
        UpdatePhase.Downloading => $"正在下载新版本 {Version}（{Progress}%）",
        UpdatePhase.Ready => $"新版本 {Version} 已下载，重启后生效",
        UpdatePhase.Failed => "检查失败，稍后再试",
        _ => "已是最新版本" + (LastCheck is { } at ? " · 上次检查 " + CheckTime(at, now) : ""),
    };

    private static string CheckTime(DateTimeOffset at, DateTimeOffset now)
    {
        var local = at.ToLocalTime();
        return local.Date == now.ToLocalTime().Date ? local.ToString("HH:mm", Chinese) : local.ToString("M月d日 HH:mm", Chinese);
    }
}
