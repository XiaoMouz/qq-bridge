using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
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
        Detail("提及和回复");
        var includeAll = new CheckBox { Content = "包含 @全体成员", IsChecked = true };
        var status = new TextBlock { Style = Res<Microsoft.UI.Xaml.Style>("SecondaryCaptionTextBlockStyle") };
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
                // 原消息在已加载的时间线里就显示发送者和内容，否则只写序号；点卡片跳到原消息。
                string preview = timelineMessages.TryGetValue(mention.Seq, out var original) && original.ChatId == chat
                    ? SenderDisplay(original) + "：" + (original.Text.Length > 0 ? original.Text : "[消息]") : $"消息 #{mention.Seq}";
                var seen = new Button { Content = "已读" };
                var row = Card(string.Join(" · ", labels), preview.Replace('\n', ' '), (mention.Flags & 256) != 0 && (mention.Flags & 96) == 0 ? "\uE97A" : "\uE910", seen, async () =>
                {
                    ct.ThrowIfCancellationRequested();
                    if (runtime == session) await Go(ChatKey(chat), () => OpenChat(chat, mention.Seq));
                });
                seen.Click += async (_, _) => await Guard(async () =>
                {
                    ct.ThrowIfCancellationRequested();
                    bool success = await vm.MarkSeenAsync([mention.Seq], ct);
                    ct.ThrowIfCancellationRequested();
                    if (runtime != session) return;
                    Render();
                    if (!success) status.Text = vm.MarkSeen.Error ?? "标记未完成，请刷新确认。";
                });
                rows.Children.Add(row);
            }
            // 数量由列表本身表达；只在出错和空的时候写一行。
            status.Text = vm.Load.State == OperationState.Failed ? "加载失败：" + vm.Load.Error : vm.Items.Count == 0 ? "没有未读的 @我 和回复我" : "";
            status.Visibility = status.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
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
                    refreshRequested = false;
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
        var toolbar = ActionRow(("刷新", "\uE72C", Reload)); toolbar.Children.Add(includeAll);
        Details.Children.Add(toolbar);
        Details.Children.Add(status); Details.Children.Add(rows);
        await Reload();
    }

    private async Task ShowReactionUsers(Message message, string emojiId)
    {
        var session = runtime;
        if (session is null) return;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(pageTask?.Token ?? lifetime.Token, lifetime.Token);
        using var vm = new ReactionUsersViewModel(message.ChatId, message.Seq, emojiId, session.ListReactionUsersAsync, new UiDispatcher(DispatcherQueue));
        // 和 iOS 的回应名单一样：头像 + 名字一行一个，不写「N 人」；标题用表情本身。
        var users = new StackPanel { Spacing = 4, MinWidth = 280 };
        await vm.LoadAsync(cancellation.Token);
        cancellation.Token.ThrowIfCancellationRequested();
        if (runtime != session) return;
        if (vm.Load.State == OperationState.Failed) users.Children.Add(Text("加载失败：" + vm.Load.Error));
        foreach (var user in vm.Users)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(0, 4, 0, 4) };
            var avatar = new PersonPicture { Width = 28, Height = 28, DisplayName = user.DisplayName, Tag = user.UserId };
            avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, user.UserId);
            row.Children.Add(avatar);
            row.Children.Add(new TextBlock { Text = user.DisplayName, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
            ToolTipService.SetToolTip(row, user.UserId.ToString());
            users.Children.Add(row);
        }
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (FaceImage(emojiId, 28) is { } face) title.Children.Add(face); else title.Children.Add(new TextBlock { Text = emojiId });
        title.Children.Add(new TextBlock { Text = "的回应", VerticalAlignment = VerticalAlignment.Center });
        if (runtime == session)
            await new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = new ScrollViewer { Content = users, MaxHeight = 420 }, CloseButtonText = "关闭", DefaultButton = ContentDialogButton.Close }.ShowAsync();
        cancellation.Cancel();
    }
}
