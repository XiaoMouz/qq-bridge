using BetterChat.Application;
using BetterChat.Infrastructure;
using Microsoft.UI.Xaml;
using Qqbridge.V1;

namespace BetterChat;

// 主窗口的连接提示：同步中在「消息」标题下一行小字，连不上服务器、要重新登录、QQ 掉线时列表上方一条横幅。
public sealed partial class MainWindow
{
    // QQ 是否在线：null = 还不知道（还没查到，或服务器本身连不上）。
    private bool? qqOnline;

    // 调试：-debugConnection <状态文字|qqoffline> 固定显示某种提示，用来看横幅布局（真的断网、让 QQ 掉线代价太大）。
    private static readonly string? debugConnection = Environment.GetCommandLineArgs() is var args && Array.IndexOf(args, "-debugConnection") is var at and >= 0 && at + 1 < args.Length ? args[at + 1] : null;

    private void UpdateConnectionNotice()
    {
        var notice = api is null ? ConnectionNotice.None
            : debugConnection == "qqoffline" ? ConnectionNotice.Describe("已连接", false)
            : debugConnection is not null ? ConnectionNotice.Describe(debugConnection, qqOnline)
            : ConnectionNotice.Describe(connectionStatus, qqOnline);
        bool syncing = notice.Syncing && section == "messages";
        SyncCaption.Visibility = syncing ? Visibility.Visible : Visibility.Collapsed; SyncRing.IsActive = syncing;
        ConnectionBanner.Message = notice.Message ?? "";
        ConnectionBanner.IsOpen = notice.Message is not null;
        QqLoginAction.Visibility = notice.OffersQqLogin ? Visibility.Visible : Visibility.Collapsed;
    }

    // 和 iOS 一样每 60 秒问一次服务端 QQ 在不在线；窗口不在前台时跳过。QQ 掉线时 GetStatus 要等二十多秒（2026-10-19 实测），放后台不挡界面。
    private async Task WatchQqStatus(ClientSessionRuntime session, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (windowActive || qqOnline is null)
                {
                    bool? online;
                    try
                    {
                        var status = await session.GetStatusAsync(new GetStatusRequest(), ct);
                        online = status.Qq.Count > 0 && status.Qq.All(q => q.Connected);
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception) { online = null; }
                    if (runtime != session) return;
                    qqOnline = online; UpdateConnectionNotice();
                }
                await Task.Delay(TimeSpan.FromSeconds(60), ct);
            }
        }
        catch (OperationCanceledException) { }
    }

    // 扫码登录成功后不必等下一轮查询，横幅马上收起。
    private void QqLoggedIn() { if (qqOnline != true) { qqOnline = true; UpdateConnectionNotice(); } }

    private void QqLoginActionClicked(object sender, RoutedEventArgs e) => _ = Guard(() => Go("qq-login", ShowQqLogin));
}
