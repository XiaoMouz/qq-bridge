using BetterChat.Application.ViewModels;
using BetterChat.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ChooseSticker()
    {
        var session = runtime;
        long chat = selectedChat, reply = replySeq;
        if (session is null || chat <= 0) return;
        var sessionToken = lifetime.Token;
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(pageTask?.Token ?? sessionToken);
        using var vm = new StickerCatalogViewModel(session.ListStickersAsync, session.PrepareStickersAsync, session.AddStickerAsync, new UiDispatcher(DispatcherQueue));
        var ct = cancel.Token;
        var list = new ListView { Height = 260, DisplayMemberPath = "Title", SelectionMode = ListViewSelectionMode.Single };
        var preview = new Image { Height = 160, MaxWidth = 320 };
        var status = Text("正在加载收藏表情…", 12);
        var panel = new StackPanel { Width = 420, Spacing = 8 };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "收藏表情", Content = panel,
            PrimaryButtonText = "发送", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        string? selected = null;
        bool busy = false;
        void Render()
        {
            var previous = selected;
            list.ItemsSource = vm.Items.Select(s => new ListEntry(string.IsNullOrWhiteSpace(s.Desc) ? "表情 " + s.Md5[..Math.Min(8, s.Md5.Length)] : s.Desc, "", "", s)).ToArray();
            if (previous is not null) list.SelectedItem = ((IEnumerable<ListEntry>)list.ItemsSource).FirstOrDefault(r => ((Sticker)r.Value).Md5 == previous);
        }
        async Task Load(bool refresh)
        {
            if (busy) return; busy = true;
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                bool success = await vm.LoadAsync(refresh, ct); ct.ThrowIfCancellationRequested();
                status.Text = success ? $"{vm.Items.Count} 个表情；选择后点击准备，可预览并发送。" : vm.Load.Error ?? "加载失败，请重试。";
                if (success) Render();
            }
            finally { busy = false; }
        }
        async Task Prepare()
        {
            if (busy || selected is null) return;
            string target = selected; busy = true; dialog.IsPrimaryButtonEnabled = false;
            try
            {
                bool ready = await vm.PrepareAsync([target], ct); ct.ThrowIfCancellationRequested();
                if (!ready) { status.Text = vm.Prepare.Error ?? "准备失败，请重试。"; return; }
                var item = vm.Items.FirstOrDefault(s => s.Md5 == target);
                if (item is null || item.Sha256.Length != 64) { status.Text = "表情尚未准备好，可再次尝试。"; return; }
                var uri = await PreviewUri(session.Api, item.ThumbSha256.Length == 64 ? item.ThumbSha256 : item.Sha256, ct);
                ct.ThrowIfCancellationRequested();
                if (selected != target) return;
                preview.Source = new BitmapImage(uri); status.Text = "已准备，可以发送。";
                dialog.IsPrimaryButtonEnabled = true;
            }
            finally { busy = false; }
        }
        list.SelectionChanged += (_, _) =>
        {
            selected = (list.SelectedItem as ListEntry)?.Value is Sticker item ? item.Md5 : null;
            preview.Source = null; dialog.IsPrimaryButtonEnabled = false;
        };
        panel.Children.Add(status); panel.Children.Add(list); panel.Children.Add(preview);
        panel.Children.Add(ActionButton("准备所选表情 / 重试", Prepare));
        panel.Children.Add(ActionButton("从 QQ 刷新收藏", () => Load(true)));
        dialog.Opened += async (_, _) => await Guard(() => Load(false));
        dialog.Closed += (_, _) => cancel.Cancel();
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary || runtime != session || selectedChat != chat || selected is null) return;
        var request = vm.CreateMessage(selected, chat, RandomId(), reply);
        await session.SendMessageAsync(request, sessionToken);
    }

    private async Task AddMessageSticker(string sha, ClientSessionRuntime session)
    {
        if (runtime != session) return;
        using var vm = new StickerCatalogViewModel(session.ListStickersAsync, session.PrepareStickersAsync, session.AddStickerAsync, new UiDispatcher(DispatcherQueue));
        if (!await vm.AddAsync(sha, lifetime.Token)) throw new IOException(vm.Add.Error ?? "收藏结果待确认，请刷新收藏列表。");
        if (runtime == session) { Notice.Message = "已收藏表情。"; Notice.Severity = InfoBarSeverity.Success; Notice.IsOpen = true; }
    }
}
