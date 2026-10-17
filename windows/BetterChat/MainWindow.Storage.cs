using Microsoft.UI.Xaml;
using BetterChat.Core;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowStorageChats(string category)
    {
        if (runtime is not { } session) return;
        var ct = NewPage(); selectedChat = 0;
        var load = new RpcOperationViewModel<ListStorageChatsRequest, ListStorageChatsResponse>(session.ListStorageChatsAsync, new UiDispatcher(DispatcherQueue), false); featurePage = load;
        Detail(Category(category), "按会话查看服务端占用");
        var request = new ListStorageChatsRequest { Limit = 200 }; request.Categories.Add(category);
        if (!await load.ExecuteAsync(request, ct))
        {
            ct.ThrowIfCancellationRequested();
            if (featurePage != load || runtime != session) return;
            throw new IOException(load.Error ?? "存储会话加载失败。");
        }
        ct.ThrowIfCancellationRequested();
        if (featurePage != load || runtime != session) return;
        var response = load.Result!;
        foreach (var chat in response.Chats)
            Details.Children.Add(ActionButton($"{PeerName(chat.PeerId, chat.Scene)} · {Bytes(chat.Bytes)} · {chat.Count:N0} 项",
                () => StorageCategories.HasMediaItems(category)
                    ? Go($"storage-items:{chat.ChatId}:{category}", () => ShowStorageItems(chat.ChatId, category))
                    : Go("chat-storage:" + chat.ChatId, () => ShowChatStorage(chat.ChatId))));
        if (response.Chats.Count == 0) Details.Children.Add(Text("此分类暂无内容。"));
    }

    private async Task ShowStorageItems(long chat, string category)
    {
        if (runtime is not { } session) return;
        var ct = NewPage();
        var vm = new StorageItemsViewModel(chat, category, session.ListStorageItemsAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        Detail(Category(category), "会话媒体 · 按大小排序");
        Details.Children.Add(ActionButton("清理此会话的媒体原件…", () => PlanStorageCleanup(chat)));
        Details.Children.Add(ActionButton("会话存储详情与生效策略", () => Go("chat-storage:" + chat, () => ShowChatStorage(chat))));
        var rows = new StackPanel { Spacing = 12 }; Details.Children.Add(rows);
        bool loading = false;
        var seen = new HashSet<string>();
        var more = new Button { Content = "加载更多" }; Details.Children.Add(more);
        async Task Load()
        {
            if (loading) return; loading = true; more.IsEnabled = false;
            try
            {
                if (!await vm.LoadMoreAsync(ct))
                {
                    ct.ThrowIfCancellationRequested();
                    if (featurePage != vm || runtime != session || !vm.HasMore) return;
                    throw new IOException(vm.Load.Error ?? "存储列表加载失败。");
                }
                ct.ThrowIfCancellationRequested();
                if (featurePage != vm || runtime != session) return;
                foreach (var item in vm.Items)
                {
                    if (!seen.Add(item.Sha256)) continue;
                    var panel = new StackPanel { Spacing = 6 };
                    panel.Children.Add(Text(item.Name.Length > 0 ? item.Name : Category(item.Category), 18));
                    panel.Children.Add(Text($"{Bytes(item.Size)} · {(item.State == "purged" ? "原件已清理" : item.Tier == "cold" ? "冷存储" : "热存储")} · {item.RefChats} 个会话引用", 12));
                    panel.Children.Add(ActionButton("查看引用位置", async () =>
                    {
                        var usage = await session.ListMediaUsagesAsync(new() { Sha256 = item.Sha256 }, ct); ct.ThrowIfCancellationRequested();
                        if (featurePage != vm || runtime != session) return;
                        var choices = new ListView { MaxHeight = 420, SelectionMode = ListViewSelectionMode.Single };
                        foreach (var u in usage.Usages) choices.Items.Add(new ListEntry(PeerName(u.PeerId, u.Scene), u.MessageSeq > 0 ? $"消息 #{u.MessageSeq}" : "群文件或服务事件", "", u));
                        choices.DisplayMemberPath = "Title";
                        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "引用位置", Content = choices, PrimaryButtonText = "打开消息", CloseButtonText = "关闭", IsPrimaryButtonEnabled = false };
                        choices.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = choices.SelectedItem is ListEntry { Value: MediaUsage { MessageSeq: > 0 } };
                        if (await dialog.ShowAsync() == ContentDialogResult.Primary && !ct.IsCancellationRequested && featurePage == vm && runtime == session && choices.SelectedItem is ListEntry { Value: MediaUsage chosen })
                            await Go(ChatKey(chosen.ChatId), () => OpenChat(chosen.ChatId, chosen.MessageSeq));
                    }));
                    rows.Children.Add(panel);
                }
                more.Visibility = vm.HasMore ? Visibility.Visible : Visibility.Collapsed;
                if (rows.Children.Count == 0) rows.Children.Add(Text("暂无内容。"));
            }
            finally { loading = false; more.IsEnabled = true; }
        }
        more.Click += async (_, _) => await Guard(Load);
        await Load();
    }

    private async Task PlanStorageCleanup(long chat)
    {
        var session = runtime; if (session is null) return;
        var ct = pageTask?.Token ?? lifetime.Token;
        using var vm = new CleanupViewModel(chat, session.PlanCleanupAsync, session.ExecuteCleanupAsync, new UiDispatcher(DispatcherQueue));
        var days = new NumberBox { Header = "清理多少天以前的原件", Value = 30, Minimum = 1, Maximum = 36500, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var type = new ComboBox { Header = "媒体类型", ItemsSource = new[] { "全部媒体", "图片", "视频", "语音", "文件", "表情" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(days); panel.Children.Add(type);
        panel.Children.Add(Text("仅清理当前会话需要的媒体原件，保留消息、缩略图和预览。下一步会先估算可释放空间。", 12));
        var configure = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "清理媒体原件", Content = panel, PrimaryButtonText = "预估空间", CloseButtonText = "取消" };
        if (await configure.ShowAsync() != ContentDialogResult.Primary) return;
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        if (!double.IsFinite(days.Value) || days.Value < 1 || days.Value > 36500 || days.Value != Math.Truncate(days.Value)) throw new ArgumentException("请输入有效的整数天数。");
        if (!await vm.Preview.ExecuteAsync(new((uint)days.Value, type.SelectedIndex > 0 ? (MediaKind)type.SelectedIndex : null), ct))
        { ct.ThrowIfCancellationRequested(); throw new IOException(vm.Preview.Error ?? "预估失败，请重试。"); }
        ct.ThrowIfCancellationRequested();
        var plan = vm.Preview.Result!;
        var result = plan.Estimate;
        var confirm = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = "确认清理原件？", CloseButtonText = "取消", PrimaryButtonText = "清理原件",
            Content = $"预计释放 {Bytes(result.FreedBytes)}，删除 {result.PurgeableBlobCount:N0} 份原件。\n另有 {result.KeptSharedBlobCount:N0} 份因其他会话仍在使用而保留。\n\n原件删除后不保证能从 QQ 重新下载。"
        };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        ct.ThrowIfCancellationRequested();
        if (runtime != session) return;
        if (!await vm.Execute.ExecuteAsync(new(plan.Id), ct))
        { ct.ThrowIfCancellationRequested(); throw new IOException((vm.Execute.Error ?? "清理未完成") + "；请重新预估确认当前状态。"); }
        ct.ThrowIfCancellationRequested();
        var cleaned = vm.Execute.Result!;
        Notice.Severity = InfoBarSeverity.Success; Notice.Message = $"已清理 {cleaned.PurgedBlobCount:N0} 份原件，释放 {Bytes(cleaned.FreedBytes)}。"; Notice.IsOpen = true;
        await ShowSetting("存储");
    }

    private async Task ShowChatStorage(long chat)
    {
        var session = runtime; if (session is null) return;
        var ct = NewPage(); Detail("会话存储详情", "服务端占用；共享内容不等于本会话可释放空间。");
        var vm = new ChatStorageViewModel(chat, session.GetChatStorageAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        if (!await vm.LoadAsync(ct: ct))
        { ct.ThrowIfCancellationRequested(); Details.Children.Add(Text(vm.Load.Error ?? "加载失败")); Details.Children.Add(ActionButton("重试", () => ShowChatStorage(chat))); return; }
        ct.ThrowIfCancellationRequested();
        if (featurePage != vm || runtime != session) return;
        var detail = vm.Detail!;
        foreach (var kind in detail.Kinds)
            Details.Children.Add(Text($"{kind.Kind}：逻辑占用 {Bytes(kind.LogicalBytes)} · 独占 {Bytes(kind.ExclusiveBytes)} · 热 {Bytes(kind.HotBytes)} · 冷 {Bytes(kind.ColdBytes)} · 已清理 {kind.PurgedCount} 项"));
        if (detail.Policy is { } policy)
            Details.Children.Add(Text($"生效策略：原件保留 {policy.KeepOriginalDays} 天；自动下载上限 {Bytes(policy.AutoFetchMaxBytes)}；{policy.ColdAfterDays} 天未访问后下沉；下沉大小门槛 {Bytes(policy.ColdMinBytes)}；热存储配额 {Bytes(policy.HotQuotaBytes)}。\n-1 表示永久保留或永不下沉；配额 0 表示不限。"));
        foreach (var item in detail.Largest)
        {
            var label = $"{item.Kind} · {Bytes(item.Size)} · {item.Tier} · {(item.Shared ? "共享" : "独占")}";
            Details.Children.Add(item.FirstSeq > 0 ? ActionButton(label, () => Go(ChatKey(chat), () => OpenChat(chat, item.FirstSeq))) : Text(label));
        }
        Details.Children.Add(ActionButton("预估清理原件…", () => PlanStorageCleanup(chat)));
        Details.Children.Add(ActionButton("编辑此会话存储策略", () => Go($"policy:{PolicyScope.Chat}::{chat}", () => ShowStoragePolicy(PolicyScope.Chat, chat: chat))));
    }
}
