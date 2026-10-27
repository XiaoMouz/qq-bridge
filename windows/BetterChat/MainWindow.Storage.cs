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
        Detail(Category(category));
        var request = new ListStorageChatsRequest { Limit = 200 }; request.Categories.Add(category);
        var loaded = PageLoading("正在统计各会话的占用…");
        bool ok;
        try { ok = await load.ExecuteAsync(request, ct); } finally { loaded(); }
        if (!ok)
        {
            ct.ThrowIfCancellationRequested();
            if (featurePage != load || runtime != session) return;
            PageError("存储会话加载失败", load.Error, () => ShowStorageChats(category)); return;
        }
        ct.ThrowIfCancellationRequested();
        if (featurePage != load || runtime != session) return;
        var response = load.Result!;
        foreach (var chat in response.Chats)
        {
            var target = chat;
            Details.Children.Add(Card(PeerName(target.PeerId, target.Scene), $"{target.Count:N0} 项", target.Scene == Scene.Group ? "\uE716" : "\uE77B", CardValue(Bytes(target.Bytes)),
                () => StorageCategories.HasMediaItems(category)
                    ? Go($"storage-items:{target.ChatId}:{category}", () => ShowStorageItems(target.ChatId, category))
                    : Go("chat-storage:" + target.ChatId, () => ShowChatStorage(target.ChatId))));
        }
        if (response.Chats.Count == 0) Details.Children.Add(Card("此分类暂无内容", null, CategoryGlyph(category)));
    }

    private async Task ShowStorageItems(long chat, string category)
    {
        if (runtime is not { } session) return;
        var ct = NewPage();
        var vm = new StorageItemsViewModel(chat, category, session.ListStorageItemsAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        Detail(Category(category));
        Details.Children.Add(ActionRow(("清理媒体原件…", "\uE74D", () => PlanStorageCleanup(chat)),
            ("存储详情与策略", "\uE946", () => Go("chat-storage:" + chat, () => ShowChatStorage(chat)))));
        var rows = new StackPanel { Spacing = 8 }; Details.Children.Add(rows);
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
                    var panel = Card(item.Name.Length > 0 ? item.Name : Category(item.Category),
                        $"{(item.State == "purged" ? "原件已清理" : item.Tier == "cold" ? "冷存储" : "热存储")} · {item.RefChats} 个会话引用",
                        CategoryGlyph(item.Category), CardValue(Bytes(item.Size)), async () =>
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
                    });
                    ToolTipService.SetToolTip(panel, "查看引用位置");
                    rows.Children.Add(panel);
                }
                more.Visibility = vm.HasMore ? Visibility.Visible : Visibility.Collapsed;
                if (rows.Children.Count == 0) rows.Children.Add(Card("暂无内容", null, CategoryGlyph(category)));
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

    // MediaKind 换成存储分类的键，复用分类的中文名和图标。
    private static string KindKey(MediaKind kind) => kind switch
    {
        MediaKind.Image => "image", MediaKind.Video => "video", MediaKind.Audio => "record", MediaKind.File => "file", MediaKind.Sticker => "sticker", _ => "other"
    };

    private async Task ShowChatStorage(long chat)
    {
        var session = runtime; if (session is null) return;
        var ct = NewPage(); Detail("会话存储详情");
        var vm = new ChatStorageViewModel(chat, session.GetChatStorageAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        var loaded = PageLoading("正在读取会话存储…");
        bool ok;
        try { ok = await vm.LoadAsync(ct: ct); } finally { loaded(); }
        if (!ok) { ct.ThrowIfCancellationRequested(); PageError("会话存储加载失败", vm.Load.Error, () => ShowChatStorage(chat)); return; }
        ct.ThrowIfCancellationRequested();
        if (featurePage != vm || runtime != session) return;
        var detail = vm.Detail!;
        Details.Children.Add(ActionRow(("清理媒体原件…", "\uE74D", () => PlanStorageCleanup(chat)),
            ("编辑存储策略", "\uE713", () => Go($"policy:{PolicyScope.Chat}::{chat}", () => ShowStoragePolicy(PolicyScope.Chat, chat: chat)))));
        Details.Children.Add(SectionHeader("按类型"));
        foreach (var kind in detail.Kinds)
            Details.Children.Add(Card(Category(KindKey(kind.Kind)), $"独占 {Bytes(kind.ExclusiveBytes)} · 热 {Bytes(kind.HotBytes)} · 冷 {Bytes(kind.ColdBytes)}" + (kind.PurgedCount > 0 ? $" · 已清理 {kind.PurgedCount} 项" : ""),
                CategoryGlyph(KindKey(kind.Kind)), CardValue(Bytes(kind.LogicalBytes))));
        if (detail.Policy is { } policy)
        {
            Details.Children.Add(SectionHeader("生效策略"));
            Details.Children.Add(Card("原件保留", policy.KeepOriginalDays < 0 ? "永久保留" : policy.KeepOriginalDays == 0 ? "只保留缩略图和预览" : $"{policy.KeepOriginalDays} 天", "\uE823"));
            Details.Children.Add(Card("自动下载上限", Bytes(policy.AutoFetchMaxBytes), "\uE896"));
            Details.Children.Add(Card("下沉到冷存储", (policy.ColdAfterDays < 0 ? "永不下沉" : $"{policy.ColdAfterDays} 天未访问后") + $" · 门槛 {Bytes(policy.ColdMinBytes)}", "\uE81E"));
            Details.Children.Add(Card("热存储配额", policy.HotQuotaBytes == 0 ? "不限" : Bytes(policy.HotQuotaBytes), "\uEDA2"));
        }
        if (detail.Largest.Count > 0) Details.Children.Add(SectionHeader("最大的文件"));
        foreach (var item in detail.Largest)
        {
            var target = item;
            Details.Children.Add(Card(Category(KindKey(target.Kind)), $"{(target.Tier == "cold" ? "冷存储" : "热存储")} · {(target.Shared ? "多个会话共享" : "本会话独占")}", CategoryGlyph(KindKey(target.Kind)),
                CardValue(Bytes(target.Size)), target.FirstSeq > 0 ? () => Go(ChatKey(chat), () => OpenChat(chat, target.FirstSeq)) : null));
        }
    }
}
