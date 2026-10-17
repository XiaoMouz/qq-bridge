using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowSharedMedia(long chat)
    {
        var session = runtime;
        if (session is null) return;
        await SaveDraft();
        if (runtime != session) return;
        var ct = NewPage();
        Detail("共享媒体", "按类型、发送者与排序查找，打开原消息或媒体");
        var kinds = new ComboBox { Header = "类型", SelectedIndex = 0 };
        foreach (var label in new[] { "全部", "图片", "视频", "语音", "文件", "表情" }) kinds.Items.Add(label);
        kinds.SelectedIndex = 0;
        var order = new ComboBox { Header = "排序", SelectedIndex = 0 };
        foreach (var label in new[] { "最新", "最早", "大小", "发送者" }) order.Items.Add(label);
        order.SelectedIndex = 0;
        var sender = new TextBox { Header = "发送者 QQ（留空表示全部）", MaxWidth = 320 };
        var status = Text("");
        var content = new StackPanel { Spacing = 8 };
        SharedMediaViewModel? vm = null;
        Button? more = null;
        void Render()
        {
            if (vm is null || ct.IsCancellationRequested || runtime != session) return;
            content.Children.Clear();
            foreach (var item in vm.Items)
            {
                var media = item.Segment?.Image?.Media ?? item.Segment?.Video?.Media ?? item.Segment?.Record?.Media
                    ?? item.Segment?.File?.Media ?? item.Segment?.MarketFace?.Media;
                var row = new StackPanel { Spacing = 4 };
                row.Children.Add(Text($"{item.Kind} · QQ {item.SenderId} · {Bytes(item.Size)} · 消息 {item.Seq}"));
                if (media is not null)
                {
                    var message = new Message { ChatId = chat, Seq = item.Seq, SenderId = item.SenderId, Time = item.Time };
                    message.Segments.Add(item.Segment);
                    row.Children.Add(ActionButton("打开媒体", async () =>
                    {
                        ct.ThrowIfCancellationRequested();
                        if (runtime == session) await ShowMedia(message, media, "共享媒体");
                    }));
                }
                row.Children.Add(ActionButton("定位原消息", async () =>
                {
                    ct.ThrowIfCancellationRequested();
                    if (runtime == session) await OpenChat(chat, item.Seq);
                }));
                content.Children.Add(row);
            }
            status.Text = vm.Load.State == OperationState.Failed ? "加载失败，可重试：" + vm.Load.Error
                : vm.PaginationError ?? $"已加载 {vm.Items.Count} 项" + (vm.HasMore ? "" : "，已到末尾");
            more!.IsEnabled = vm.HasMore && !vm.Load.IsBusy;
        }
        async Task LoadMore()
        {
            var current = vm;
            if (current is null) return;
            more!.IsEnabled = false;
            status.Text = "正在加载…";
            await current.LoadMoreAsync(ct);
            ct.ThrowIfCancellationRequested();
            if (vm == current && runtime == session) Render();
        }
        async Task ApplyFilter()
        {
            long senderId = 0;
            if (!string.IsNullOrWhiteSpace(sender.Text) && (!long.TryParse(sender.Text, out senderId) || senderId <= 0))
                throw new ArgumentException("请输入有效的发送者 QQ 号码。");
            ct.ThrowIfCancellationRequested();
            if (runtime != session) return;
            vm?.Dispose();
            MediaKind[] filter = kinds.SelectedIndex > 0 ? [(MediaKind)kinds.SelectedIndex] : [];
            vm = new SharedMediaViewModel(chat, filter, (SharedMediaOrder)Math.Max(0, order.SelectedIndex), senderId,
                session.ListSharedMediaAsync, new UiDispatcher(DispatcherQueue));
            featurePage = vm;
            content.Children.Clear();
            await LoadMore();
        }
        more = ActionButton("加载更多", LoadMore);
        Details.Children.Add(kinds); Details.Children.Add(order); Details.Children.Add(sender);
        Details.Children.Add(ActionButton("应用筛选 / 重新加载", ApplyFilter));
        Details.Children.Add(status); Details.Children.Add(content); Details.Children.Add(more);
        await ApplyFilter();
    }
}
