using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowMentions(long chat)
    {
        var session = runtime;
        if (session is null) return;
        await SaveDraft();
        if (runtime != session) return;
        var ct = NewPage();
        var vm = new MentionsViewModel(chat, true, session.ListUnreadMentionsAsync, session.MarkMentionsSeenAsync, new UiDispatcher(DispatcherQueue));
        featurePage = vm;
        Detail("提及和回复", "提及已读独立于普通消息已读；每次查询最多返回 200 项");
        var includeAll = new CheckBox { Content = "包含 @全体成员", IsChecked = true };
        var status = Text("");
        var rows = new StackPanel { Spacing = 8 };
        bool refreshing = false, refreshRequested = false;
        void Render()
        {
            if (ct.IsCancellationRequested || runtime != session) return;
            rows.Children.Clear();
            foreach (var mention in vm.Items)
            {
                var labels = new List<string>();
                if ((mention.Flags & 32) != 0) labels.Add("@我");
                if ((mention.Flags & 64) != 0) labels.Add("@全体成员");
                if ((mention.Flags & 256) != 0) labels.Add("回复我");
                var row = new StackPanel { Spacing = 4 };
                row.Children.Add(Text($"消息 {mention.Seq} · {string.Join(" / ", labels)}"));
                row.Children.Add(ActionButton("定位消息", async () =>
                {
                    ct.ThrowIfCancellationRequested();
                    if (runtime == session) await Go(ChatKey(chat), () => OpenChat(chat, mention.Seq));
                }));
                row.Children.Add(ActionButton("标记此提及已读", async () =>
                {
                    ct.ThrowIfCancellationRequested();
                    bool success = await vm.MarkSeenAsync([mention.Seq], ct);
                    ct.ThrowIfCancellationRequested();
                    if (runtime != session) return;
                    Render();
                    if (!success) status.Text = vm.MarkSeen.Error ?? "标记未完成，请刷新确认。";
                }));
                rows.Children.Add(row);
            }
            status.Text = vm.Load.State == OperationState.Failed ? "加载失败：" + vm.Load.Error : $"当前列表 {vm.Items.Count} 项";
        }
        async Task Reload()
        {
            ct.ThrowIfCancellationRequested();
            refreshRequested = true;
            if (refreshing) return;
            refreshing = true;
            try
            {
                do
                {
                    refreshRequested = false; status.Text = "正在加载…";
                    await vm.LoadAsync(0, ct);
                    ct.ThrowIfCancellationRequested(); Render();
                } while (refreshRequested);
            }
            finally { refreshing = false; }
        }
        void Invalidated(long changedChat)
        {
            if (changedChat != chat || ct.IsCancellationRequested) return;
            DispatcherQueue.TryEnqueue(async () =>
            {
                if (!ct.IsCancellationRequested && runtime == session) await Guard(Reload);
            });
        }
        session.ChatInvalidated += Invalidated;
        ct.Register(() => session.ChatInvalidated -= Invalidated);
        includeAll.Click += async (_, _) => await Guard(async () =>
        {
            ct.ThrowIfCancellationRequested();
            await vm.SetIncludeAllAsync(includeAll.IsChecked == true); Render();
        });
        Details.Children.Add(includeAll); Details.Children.Add(ActionButton("刷新", Reload));
        Details.Children.Add(status); Details.Children.Add(rows);
        await Reload();
    }

    private async Task ShowReactionUsers(Message message, string emojiId)
    {
        var session = runtime;
        if (session is null) return;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(pageTask?.Token ?? lifetime.Token, lifetime.Token);
        using var vm = new ReactionUsersViewModel(message.ChatId, message.Seq, emojiId, session.ListReactionUsersAsync, new UiDispatcher(DispatcherQueue));
        var panel = new StackPanel { Spacing = 8 };
        var status = Text("正在加载…"); var users = new StackPanel { Spacing = 4 };
        async Task Load()
        {
            await vm.LoadAsync(cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (runtime != session) return;
            users.Children.Clear();
            foreach (var user in vm.Users) users.Children.Add(Text($"{user.DisplayName}（{user.UserId}）"));
            status.Text = vm.Load.State == OperationState.Failed ? "加载失败：" + vm.Load.Error : $"{vm.Users.Count} 人";
        }
        panel.Children.Add(status); panel.Children.Add(users); panel.Children.Add(ActionButton("刷新名单", Load));
        await Load();
        cancellation.Token.ThrowIfCancellationRequested();
        if (runtime == session) await DialogBox("回应 " + emojiId, panel);
        cancellation.Cancel();
    }
}
