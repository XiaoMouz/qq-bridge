using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;
using BetterChat.Application.ViewModels;

namespace BetterChat;

public sealed partial class MainWindow
{
    // 卡片右侧的状态标签：正常用成功色底，有问题用警告 / 错误色底，一眼能看出哪一项要处理。
    private enum Health { Ok, Warning, Error }
    private static FrameworkElement StatusPill(string text, Health health) => new Border
    {
        CornerRadius = new CornerRadius(4), Padding = new Thickness(8, 2, 8, 2), VerticalAlignment = VerticalAlignment.Center,
        Background = Brush(health switch { Health.Ok => "SystemFillColorSuccessBackgroundBrush", Health.Warning => "SystemFillColorCautionBackgroundBrush", _ => "SystemFillColorCriticalBackgroundBrush" }),
        Child = new TextBlock { Text = text, Style = Res<Style>("CaptionTextBlockStyle") }
    };
    private static Health Count(long failed, long pending = 0) => failed > 0 ? Health.Error : pending > 100 ? Health.Warning : Health.Ok;
    private static string Time(long unix) => DateTimeOffset.FromUnixTimeSeconds(unix).ToLocalTime().ToString("g");

    private async Task ShowServerStatus(CancellationToken ct)
    {
        if (runtime is not { } session) return;
        var load = new RpcOperationViewModel<GetStatusRequest, GetStatusResponse>(session.GetStatusAsync, new UiDispatcher(DispatcherQueue), false);
        featurePage = load;
        var loaded = PageLoading("正在读取服务端状态…");
        bool ok;
        try { ok = await load.ExecuteAsync(new(), ct); } finally { loaded(); }
        if (!ok)
        {
            ct.ThrowIfCancellationRequested();
            if (featurePage != load || runtime != session) return;
            PageError("服务端状态加载失败", load.Error, () => ShowSetting("服务端状态")); return;
        }
        ct.ThrowIfCancellationRequested();
        if (featurePage != load || runtime != session) return;
        var response = load.Result!;
        Details.Children.Add(ActionRow(("刷新", "", () => ShowSetting("服务端状态")),
            ("存档完整性", "", () => Go(SettingKey("存档完整性"), () => ShowSetting("存档完整性")))));
        Details.Children.Add(SectionHeader("QQ"));
        foreach (var qq in response.Qq)
            Details.Children.Add(Card(qq.Nickname.Length > 0 ? qq.Nickname : "QQ 账号",
                $"QQ {qq.Uin} · " + (qq.PluginVersion.Length > 0 ? $"插件 {qq.PluginVersion} · " : "") + (qq.LastEventAt > 0 ? "最近事件 " + Time(qq.LastEventAt) : "尚未收到事件"),
                "", StatusPill(qq.Connected ? "已连接" : "未连接", qq.Connected ? Health.Ok : Health.Error)));
        Details.Children.Add(SectionHeader("队列"));
        if (response.Inbox is { } inbox)
            Details.Children.Add(Card("事件入库", $"待处理 {inbox.Pending:N0} · 失败 {inbox.Failed:N0} · 近 24 小时忽略 {inbox.Ignored24H:N0}", "",
                StatusPill(inbox.Failed > 0 ? $"{inbox.Failed:N0} 失败" : "正常", Count(inbox.Failed, inbox.Pending))));
        if (response.Outbox is { } outbox)
            Details.Children.Add(Card("发送队列", $"等待发送 {outbox.Pending:N0} · 失败 {outbox.Failed:N0}", "",
                StatusPill(outbox.Failed > 0 ? $"{outbox.Failed:N0} 失败" : "正常", Count(outbox.Failed, outbox.Pending))));
        if (response.Media is { } media)
            Details.Children.Add(Card("媒体下载", $"待处理 {media.Pending:N0} · 失败 {media.Failed:N0} · 过期 {media.Expired:N0}", "",
                StatusPill(media.Failed > 0 ? $"{media.Failed:N0} 失败" : "正常", Count(media.Failed, media.Pending))));
        if (response.Archive is { } archive)
            Details.Children.Add(Card("消息存档", $"{archive.ChatsWithHoles:N0} 个会话有缺口，共缺 {archive.MissingSeqs:N0} 条 · {archive.DeepArchiveChats:N0} 个会话开启深度归档", "",
                StatusPill(archive.ChatsWithHoles > 0 ? "有缺口" : "完整", archive.ChatsWithHoles > 0 ? Health.Warning : Health.Ok),
                () => Go(SettingKey("存档完整性"), () => ShowSetting("存档完整性"))));
        if (response.Calls is { } calls)
        {
            bool ready = calls.Configured && calls.BridgeEnabled && calls.EngineLoggedIn && calls.GatewayReachable;
            Details.Children.Add(SectionHeader("通话桥"));
            Details.Children.Add(Card("通话桥",
                $"配置{(calls.Configured ? "已完成" : "未完成")} · 信令桥{(calls.BridgeEnabled ? "已启用" : "未启用")} · 引擎{(calls.EngineLoggedIn ? "已登录" : "未登录")} · 网关{(calls.GatewayReachable ? "可达" : "不可达")}",
                "", StatusPill(ready ? "可用" : calls.PausedReason.Length > 0 ? "已暂停" : "不可用", ready ? Health.Ok : Health.Warning)));
            if (calls.PausedReason.Length > 0) Details.Children.Add(Card("暂停原因", calls.PausedReason, ""));
            if (calls.LastError.Length > 0) Details.Children.Add(Card("最近错误", calls.LastError, ""));
        }
    }

    private async Task ShowArchiveStatus(CancellationToken ct)
    {
        if (runtime is not { } session) return;
        var vm = new ArchiveViewModel(session.ListArchiveStatusAsync, session.SetDeepArchiveAsync, session.FillHolesNowAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        var loaded = PageLoading("正在读取各会话的存档状态…");
        bool ok;
        try { ok = await vm.Load.ExecuteAsync(new(), ct); } finally { loaded(); }
        if (!ok) { ct.ThrowIfCancellationRequested(); PageError("存档状态加载失败", vm.Load.Error, () => ShowSetting("存档完整性")); return; }
        var response = vm.Load.Result!;
        ct.ThrowIfCancellationRequested();
        Details.Children.Add(ActionRow(("立即补齐缺口", "", async () =>
        {
            if (!await vm.FillHoles.ExecuteAsync(new(), ct))
            {
                ct.ThrowIfCancellationRequested();
                throw new IOException((vm.FillHoles.Error ?? "补齐请求未完成。") + " 请刷新状态确认，不会自动重复提交。");
            }
            ct.ThrowIfCancellationRequested();
            Notice.Severity = InfoBarSeverity.Informational; Notice.Message = "已请求补齐缺口，稍后可刷新查看进度。"; Notice.IsOpen = true;
        }), ("刷新", "", () => ShowSetting("存档完整性"))));
        Details.Children.Add(new TextBlock { Text = "深度归档会从能取到的最早消息开始往回补，可能持续一段时间。", Style = Res<Style>("SecondaryCaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
        Details.Children.Add(SectionHeader($"会话（{response.Chats.Count:N0}）"));
        foreach (var chat in response.Chats)
        {
            var toggle = new ToggleSwitch { OnContent = "深度归档", OffContent = "深度归档", IsOn = chat.DeepArchive };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, "深度归档");
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
            string name = chat.Name.Length > 0 ? chat.Name : PeerName(chat.PeerId, chat.Scene);
            string description = (chat.Holes > 0 ? $"{chat.Holes:N0} 处缺口，缺 {chat.MissingSeqs:N0} 条" : "没有缺口") + (chat.HistoryComplete ? " · 历史已完整" : " · 还能继续往回归档");
            Details.Children.Add(Card(name, description, chat.Scene == Scene.Group ? "" : "", toggle));
        }
        if (response.Chats.Count == 0) Details.Children.Add(Card("暂无会话存档", null, ""));
    }
}
