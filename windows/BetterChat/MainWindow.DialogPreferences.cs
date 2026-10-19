using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
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
        Detail("会话设置", "改动立即保存；其他设备上的改动也会同步到这里");
        var dialog = await session.Repository.GetDialogAsync(chatId, ct);
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        if (dialog is null) { Details.Children.Add(Text("会话已不存在。")); return; }
        var vm = new DialogPreferencesViewModel(dialog, session.SetPinnedAsync, session.SetNotifyPolicyAsync, session.SetMentionAllNotifyAsync, new UiDispatcher(DispatcherQueue));
        featurePage = vm;
        var status = new TextBlock { Style = Res<Style>("SecondaryCaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(2, 4, 0, 0) };
        bool deleted = false, rendering = false;
        var policies = new[] { NotificationPolicy.Default, NotificationPolicy.All, NotificationPolicy.Mentions, NotificationPolicy.Muted, NotificationPolicy.Archived };
        // 开关和下拉框显示的是同步确认后的状态：改动只发请求，结果等同步回来再更新，失败时自动回到原状态。
        var pinned = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0 };
        var policy = new ComboBox { ItemsSource = new[] { "默认", "所有消息", "仅提及", "免打扰", "收进群助手" }, MinWidth = 160 };
        var mentionAll = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0 };
        void Render()
        {
            rendering = true;
            pinned.IsOn = vm.Pinned; mentionAll.IsOn = vm.MentionAllNotify;
            policy.SelectedIndex = vm.NotifyPolicy switch { "all" => 1, "mentions" => 2, "muted" => 3, "archived" => 4, _ => 0 };
            rendering = false;
        }
        async Task Set<TRequest, TResponse>(RpcOperationViewModel<TRequest, TResponse> operation, TRequest request)
            where TRequest : class where TResponse : class
        {
            if (runtime != session || ct.IsCancellationRequested || deleted) return;
            status.Text = "正在保存…";
            bool success = await operation.ExecuteAsync(request, ct);
            if (ct.IsCancellationRequested) return;
            status.Text = success ? "已提交，以同步回来的状态为准。"
                : (operation.Error ?? "操作未完成") + (operation.OutcomeUncertain ? "；结果待同步确认，请勿连续重复提交。" : "");
            if (!success) Render();
        }
        pinned.Toggled += async (_, _) => { if (!rendering && pinned.IsOn != vm.Pinned) await Guard(() => Set(vm.SetPinned, new BooleanPreference(pinned.IsOn))); };
        policy.SelectionChanged += async (_, _) =>
        {
            if (rendering || policy.SelectedIndex < 0) return;
            await Guard(() => Set(vm.SetPolicy, new NotificationPreference(policies[policy.SelectedIndex])));
        };
        mentionAll.Toggled += async (_, _) => { if (!rendering && mentionAll.IsOn != vm.MentionAllNotify) await Guard(() => Set(vm.SetMentionAll, new BooleanPreference(mentionAll.IsOn))); };
        Details.Children.Add(Card("置顶", "置顶的会话固定在列表最上面", "\uE718", pinned));
        Details.Children.Add(Card("通知", "免打扰仍会收消息但不提醒；收进群助手的群折叠到「群助手」里", "\uEA8F", policy));
        if (dialog.Scene == Scene.Group)
            Details.Children.Add(Card("@全体成员提醒", "关闭后 @全体成员 不再算作提醒", "\uE716", mentionAll));
        Details.Children.Add(status);
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
