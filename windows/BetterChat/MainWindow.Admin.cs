using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;
using BetterChat.Application.ViewModels;

namespace BetterChat;

public sealed partial class MainWindow
{
    private void StatusCard(string heading, params string[] lines)
    {
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(Text(heading, 20));
        foreach (var line in lines) body.Children.Add(Text(line));
        Details.Children.Add(new Border
        {
            Child = body, Padding = new Thickness(20), CornerRadius = new CornerRadius(8),
            Background = Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1)
        });
    }
    private async Task ShowServerStatus(CancellationToken ct)
    {
        if (runtime is not { } session) return;
        var load = new RpcOperationViewModel<GetStatusRequest, GetStatusResponse>(session.GetStatusAsync, new UiDispatcher(DispatcherQueue), false);
        featurePage = load;
        if (!await load.ExecuteAsync(new(), ct))
        {
            ct.ThrowIfCancellationRequested();
            if (featurePage != load || runtime != session) return;
            throw new IOException(load.Error ?? "服务端状态加载失败。");
        }
        ct.ThrowIfCancellationRequested();
        if (featurePage != load || runtime != session) return;
        var response = load.Result!;
        Details.Children.Add(ActionButton("刷新状态", () => ShowSetting("服务端状态")));
        foreach (var qq in response.Qq)
            StatusCard(qq.Nickname.Length > 0 ? qq.Nickname : "QQ 账号", $"QQ {qq.Uin} · 插件{(qq.Connected ? "已连接" : "未连接")}", "插件版本：" + qq.PluginVersion,
                qq.LastEventAt > 0 ? "最近事件：" + DateTimeOffset.FromUnixTimeSeconds(qq.LastEventAt).ToLocalTime().ToString("g") : "尚未收到事件");
        if (response.Inbox is { } inbox) StatusCard("事件入库", $"待处理 {inbox.Pending:N0} · 失败 {inbox.Failed:N0}", $"近 24 小时忽略 {inbox.Ignored24H:N0} 项");
        if (response.Outbox is { } outbox) StatusCard("发送队列", $"等待发送 {outbox.Pending:N0} · 失败 {outbox.Failed:N0}");
        if (response.Media is { } media) StatusCard("媒体下载", $"待处理 {media.Pending:N0} · 失败 {media.Failed:N0} · 过期 {media.Expired:N0}");
        if (response.Archive is { } archive) StatusCard("消息存档", $"{archive.ChatsWithHoles:N0} 个会话有缺口 · 共 {archive.MissingSeqs:N0} 条", $"{archive.DeepArchiveChats:N0} 个会话开启深度归档");
        if (response.Calls is { } calls)
        {
            StatusCard("通话桥", $"配置：{(calls.Configured ? "已配置" : "未配置")} · 信令桥：{(calls.BridgeEnabled ? "已启用" : "未启用")}",
                $"引擎：{(calls.EngineLoggedIn ? "已登录" : "未登录")} · 网关：{(calls.GatewayReachable ? "可达" : "不可达")}");
            if (calls.PausedReason.Length > 0) Details.Children.Add(Text("暂停原因：" + calls.PausedReason));
            if (calls.LastError.Length > 0) Details.Children.Add(Text("最近错误：" + calls.LastError));
        }
        Details.Children.Add(ActionButton("查看存档完整性", () => Go(SettingKey("存档完整性"), () => ShowSetting("存档完整性"))));
    }
    private async Task ShowArchiveStatus(CancellationToken ct)
    {
        if (runtime is not { } session) return;
        var vm = new ArchiveViewModel(session.ListArchiveStatusAsync, session.SetDeepArchiveAsync, session.FillHolesNowAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        if (!await vm.Load.ExecuteAsync(new(), ct)) { ct.ThrowIfCancellationRequested(); throw new IOException(vm.Load.Error ?? "存档状态加载失败。"); }
        var response = vm.Load.Result!;
        ct.ThrowIfCancellationRequested();
        Details.Children.Add(Text("深度归档会从可获取的最早消息开始补齐，可能持续一段时间。"));
        Details.Children.Add(ActionButton("刷新", () => ShowSetting("存档完整性")));
        Details.Children.Add(ActionButton("立即补齐缺口", async () =>
        {
            if (!await vm.FillHoles.ExecuteAsync(new(), ct))
            {
                ct.ThrowIfCancellationRequested();
                throw new IOException((vm.FillHoles.Error ?? "补齐请求未完成。") + " 请刷新状态确认，不会自动重复提交。");
            }
            ct.ThrowIfCancellationRequested();
            Notice.Severity = InfoBarSeverity.Informational; Notice.Message = "已请求补齐缺口，稍后可刷新查看进度。"; Notice.IsOpen = true;
        }));
        foreach (var chat in response.Chats)
        {
            var panel = new StackPanel { Spacing = 8 };
            panel.Children.Add(Text(chat.Name.Length > 0 ? chat.Name : PeerName(chat.PeerId, chat.Scene), 18));
            panel.Children.Add(Text($"{chat.Holes:N0} 处缺口 · 缺少 {chat.MissingSeqs:N0} 条消息 · {(chat.HistoryComplete ? "历史已完整" : "仍可继续归档")}", 12));
            var toggle = new ToggleSwitch { Header = "深度归档", OnContent = "开启", OffContent = "关闭", IsOn = chat.DeepArchive };
            bool restoring = false;
            toggle.Toggled += async (_, _) =>
            {
                if (restoring) return;
                bool desired = toggle.IsOn;
                toggle.IsEnabled = false;
                await Guard(async () =>
                {
                    try
                    {
                        if (!await vm.SetDeepArchive.ExecuteAsync(new() { ChatId = chat.ChatId, Enabled = desired }, ct))
                        { ct.ThrowIfCancellationRequested(); throw new IOException(vm.SetDeepArchive.Error ?? "归档设置未完成，请刷新确认。"); }
                        ct.ThrowIfCancellationRequested(); chat.DeepArchive = desired;
                    }
                    catch { restoring = true; toggle.IsOn = chat.DeepArchive; restoring = false; throw; }
                });
                toggle.IsEnabled = true;
            };
            panel.Children.Add(toggle); Details.Children.Add(panel);
        }
        if (response.Chats.Count == 0) Details.Children.Add(Text("暂无会话存档。"));
    }
}
