using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private string historyError = "";
    private bool windowActive;
    private ScrollViewer? messageScroll;
    private ReadReceiptCoordinator? readReceipts;
    private readonly DispatcherTimer readTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };

    private void InitializeChatState()
    {
        Activated += (_, args) =>
        {
            windowActive = args.WindowActivationState != WindowActivationState.Deactivated;
            if (windowActive) ScheduleRead(); else readTimer.Stop();
            _ = UpdateActiveChat();
        };
        Messages.Loaded += (_, _) =>
        {
            var scroll = Descendant<ScrollViewer>(Messages);
            if (scroll is null || ReferenceEquals(scroll, messageScroll)) return;
            if (messageScroll is not null) messageScroll.ViewChanged -= MessageScrollChanged;
            messageScroll = scroll; scroll.ViewChanged += MessageScrollChanged;
        };
        readTimer.Tick += async (_, _) =>
        {
            readTimer.Stop();
            if (!CanMarkRead() || readReceipts is not { } receipts) return;
            long chat = selectedChat;
            long max = Messages.Items.OfType<TimelineEntry>().Select(r => r.Value).OfType<Message>().Select(m => m.Seq).DefaultIfEmpty().Max();
            var ct = pageTask?.Token ?? lifetime.Token;
            try
            {
                if (await receipts.SubmitAsync(chat, max, dialogIndex.GetValueOrDefault(chat)?.ReadInboxMaxSeq ?? 0, ct)) ScheduleRead();
            }
            catch (OperationCanceledException) { }
            catch (Exception) { /* 下次滚动、激活或同步时重试；已读失败不打断阅读。 */ }
        };
    }
    private async Task UpdateActiveChat()
    {
        if (runtime is not { } session) return;
        long chat = windowActive && ChatPanel.Visibility == Visibility.Visible ? selectedChat : 0;
        try { await session.SetActiveChatAsync(chat, lifetime.Token); }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        // 活跃租约失败不打断阅读；前台下次续期重试，后台租约由服务端在两分钟后过期。
        catch (Exception) { }
    }
    private bool AtMessageBottom() => messageScroll is not null && messageScroll.ScrollableHeight - messageScroll.VerticalOffset < 40;
    private bool CanMarkRead() => windowActive && selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible
        && historyWindow?.FollowsLatest == true && !historyLoading && historyError.Length == 0 && AtMessageBottom();
    private void ScheduleRead()
    {
        if (CanMarkRead() && !readTimer.IsEnabled) readTimer.Start();
    }
    private void MessageScrollChanged(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        if (args.IsIntermediate) return;
        followLatest = historyWindow?.FollowsLatest == true && AtMessageBottom();
        ScheduleRead();
    }
    private async void RetryChatLoad(object sender, RoutedEventArgs args) => await Guard(() => OpenChat(selectedChat, historyAnchor));
    private void UpdateChatState()
    {
        bool empty = Messages.Items.Count == 0;
        ChatState.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ChatLoading.IsActive = empty && historyLoading;
        ChatLoading.Visibility = empty && historyLoading ? Visibility.Visible : Visibility.Collapsed;
        ChatStateTitle.Text = historyLoading ? "正在加载消息" : historyError.Length > 0 ? "消息加载失败" : "暂无消息";
        ChatStateDescription.Text = historyLoading ? "正在获取此会话的聊天记录…" : historyError.Length > 0 ? historyError : "可以从下方发送第一条消息。";
        ChatRetry.Visibility = !historyLoading && historyError.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ChatLoadNotice.IsOpen = !empty && historyError.Length > 0;
        ChatLoadNotice.Message = historyError.Length > 0 ? "已显示本地缓存。" + historyError : "";
        ScheduleRead();
    }
}
