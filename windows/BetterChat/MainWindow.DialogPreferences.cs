using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowDialogPreferences(long chatId)
    {
        var session = runtime;
        if (session is null) return;
        await SaveDraft();
        if (runtime != session) return;
        var ct = NewPage();
        Detail("会话设置", "保存后等待同步确认；其他设备的变更也会更新到这里。");
        var dialog = await session.Repository.GetDialogAsync(chatId, ct);
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        if (dialog is null) { Details.Children.Add(Text("会话已不存在。")); return; }
        var vm = new DialogPreferencesViewModel(dialog, session.SetPinnedAsync, session.SetNotifyPolicyAsync, session.SetMentionAllNotifyAsync, new UiDispatcher(DispatcherQueue));
        featurePage = vm;
        var confirmed = Text("");
        var status = Text("", 12);
        bool deleted = false;
        var policies = new[] { NotificationPolicy.Default, NotificationPolicy.All, NotificationPolicy.Mentions, NotificationPolicy.Muted, NotificationPolicy.Archived };
        var policy = new ComboBox { Header = "通知策略", ItemsSource = new[] { "默认", "所有消息", "仅提及", "免打扰", "收进群助手" }, SelectedIndex = 0, MinWidth = 200 };
        void Render() => confirmed.Text = $"已确认：{(vm.Pinned ? "已置顶" : "未置顶")} · 通知 {vm.NotifyPolicy} · @全体成员{(vm.MentionAllNotify ? "提醒" : "不提醒")}";
        async Task Set<TRequest, TResponse>(RpcOperationViewModel<TRequest, TResponse> operation, TRequest request)
            where TRequest : class where TResponse : class
        {
            if (runtime != session || ct.IsCancellationRequested || deleted) return;
            bool success = await operation.ExecuteAsync(request, ct);
            if (ct.IsCancellationRequested) return;
            status.Text = success ? "请求已提交，确认状态以同步结果为准。"
                : (operation.Error ?? "操作未完成") + (operation.OutcomeUncertain ? "；结果待同步确认，请勿连续重复提交。" : "");
        }
        Details.Children.Add(confirmed);
        Details.Children.Add(ActionButton("切换置顶", () => Set(vm.SetPinned, new BooleanPreference(!vm.Pinned))));
        policy.SelectedIndex = vm.NotifyPolicy switch { "all" => 1, "mentions" => 2, "muted" => 3, "archived" => 4, _ => 0 };
        Details.Children.Add(policy);
        Details.Children.Add(ActionButton("保存通知策略", () => policy.SelectedIndex < 0 ? Task.CompletedTask : Set(vm.SetPolicy, new NotificationPreference(policies[policy.SelectedIndex]))));
        if (dialog.Scene == Scene.Group)
            Details.Children.Add(ActionButton("切换 @全体成员提醒", () => Set(vm.SetMentionAll, new BooleanPreference(!vm.MentionAllNotify))));
        Details.Children.Add(status);
        Details.Children.Add(ActionButton("返回聊天", () => OpenChat(chatId)));
        vm.PropertyChanged += (_, _) => Render();
        Render();
        bool refreshing = false, requested = false;
        async Task Refresh()
        {
            if (refreshing) { requested = true; return; }
            refreshing = true;
            try
            {
                do
                {
                    requested = false;
                    var updated = await session.Repository.GetDialogAsync(chatId, ct);
                    ct.ThrowIfCancellationRequested();
                    if (runtime != session) return;
                    if (updated is null) { deleted = true; status.Text = "会话已删除，请返回会话列表。"; vm.Dispose(); return; }
                    await vm.ApplyDialogAsync(updated);
                } while (requested);
            }
            finally { refreshing = false; }
        }
        void Changed(long chat)
        {
            if (chat == chatId) DispatcherQueue.TryEnqueue(async () =>
            {
                if (!ct.IsCancellationRequested && runtime == session) await Guard(Refresh);
            });
        }
        session.ChatInvalidated += Changed;
        ct.Register(() => session.ChatInvalidated -= Changed);
        // 补读订阅建立前的更新，避免初始读取与监听之间的窗口漏掉变更。
        await Refresh();
    }
}
