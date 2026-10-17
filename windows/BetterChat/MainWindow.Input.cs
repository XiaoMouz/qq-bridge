using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;

namespace BetterChat;

// 输入区：附件先进预览条、点发送才上传（同 iOS）；拖放和粘贴图片 / 文件；多选转发；会话内查找条。
public sealed partial class MainWindow
{
    private sealed record PendingAttachment(StorageFile File, bool IsImage);
    private readonly List<PendingAttachment> attachments = [];
    private long attachmentsChat;
    private static readonly HashSet<string> ImageTypes = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"];
    private const int MaxAttachments = 9;

    private static bool IsImageFile(StorageFile file) => ImageTypes.Contains(file.FileType.ToLowerInvariant()) || file.ContentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase);

    private void AddAttachments(IEnumerable<IStorageItem> items)
    {
        if (selectedChat == 0) return;
        // 附件属于当前会话；换了会话再加，先清掉上一个会话没发的。
        if (attachmentsChat != selectedChat) { attachments.Clear(); attachmentsChat = selectedChat; }
        foreach (var file in items.OfType<StorageFile>())
        {
            if (attachments.Count >= MaxAttachments) { Notice.Severity = InfoBarSeverity.Warning; Notice.Message = $"一次最多发送 {MaxAttachments} 个附件。"; Notice.IsOpen = true; break; }
            if (attachments.Any(a => a.File.Path.Length > 0 && a.File.Path == file.Path)) continue;
            attachments.Add(new(file, IsImageFile(file)));
        }
        RenderAttachments();
    }

    private void RenderAttachments()
    {
        if (attachmentsChat != selectedChat) attachments.Clear();
        AttachmentItems.Children.Clear();
        AttachmentStrip.Visibility = attachments.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var attachment in attachments.ToList())
        {
            var grid = new Grid { ColumnSpacing = 8 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            FrameworkElement thumb;
            if (attachment.IsImage)
            {
                var image = new Image { Width = 48, Height = 48, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill };
                _ = LoadThumbnail(image, attachment.File);
                thumb = new Border { CornerRadius = new CornerRadius(4), Child = image };
            }
            else thumb = new Border { Width = 48, Height = 48, CornerRadius = new CornerRadius(4), Background = Brush("SubtleFillColorSecondaryBrush"), Child = new FontIcon { Glyph = "", FontSize = 20 } };
            grid.Children.Add(thumb);
            var name = new TextBlock { Text = attachment.File.Name, MaxWidth = 160, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, Style = Res<Style>("CaptionTextBlockStyle") };
            Grid.SetColumn(name, 1); grid.Children.Add(name);
            var remove = new Button { Content = "", Style = Res<Style>("IconButtonStyle"), Width = 24, Height = 24, FontSize = 10, VerticalAlignment = VerticalAlignment.Top };
            ToolTipService.SetToolTip(remove, "移除"); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(remove, "移除 " + attachment.File.Name);
            remove.Click += (_, _) => { attachments.Remove(attachment); RenderAttachments(); };
            Grid.SetColumn(remove, 2); grid.Children.Add(remove);
            AttachmentItems.Children.Add(new Border { Style = Res<Style>("AttachmentChipStyle"), Child = grid });
        }
    }

    private static async Task LoadThumbnail(Image image, StorageFile file)
    {
        try
        {
            using var thumbnail = await file.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.PicturesView, 96);
            var bitmap = new BitmapImage();
            await bitmap.SetSourceAsync(thumbnail);
            image.Source = bitmap;
        }
        catch (Exception) { /* 没有缩略图时留空框，不影响发送。 */ }
    }

    private async Task PickAttachments(bool media)
    {
        if (selectedChat == 0) return;
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (media) foreach (var type in new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".mp4", ".mov", ".mkv", ".webm" }) picker.FileTypeFilter.Add(type);
        else picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        if (files is { Count: > 0 }) AddAttachments(files);
        Composer.Focus(FocusState.Keyboard);
    }
    private async void AttachMediaClicked(object sender, RoutedEventArgs e) => await Guard(() => PickAttachments(true));
    private async void AttachFileClicked(object sender, RoutedEventArgs e) => await Guard(() => PickAttachments(false));
    private async void RecordVoiceClicked(object sender, RoutedEventArgs e) { long chat = selectedChat; if (chat != 0) await Guard(() => ShowVoiceRecording(chat)); }

    private void ComposerDragOver(object sender, DragEventArgs e)
    {
        if (selectedChat == 0 || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "添加为附件";
    }
    private async void ComposerDrop(object sender, DragEventArgs e) => await Guard(async () =>
    {
        if (selectedChat == 0 || !e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        AddAttachments(await e.DataView.GetStorageItemsAsync());
    });

    // 粘贴：剪贴板里是文件或图片就变成附件，文字照常进输入框。
    private async void ComposerPaste(object sender, TextControlPasteEventArgs e)
    {
        var data = Clipboard.GetContent();
        if (selectedChat == 0 || data.Contains(StandardDataFormats.Text)) return;
        if (data.Contains(StandardDataFormats.StorageItems))
        {
            e.Handled = true;
            await Guard(async () => AddAttachments(await data.GetStorageItemsAsync()));
        }
        else if (data.Contains(StandardDataFormats.Bitmap))
        {
            e.Handled = true;
            await Guard(async () =>
            {
                var reference = await data.GetBitmapAsync();
                using var source = await reference.OpenReadAsync();
                var folder = await StorageFolder.GetFolderFromPathAsync(Path.GetTempPath());
                var target = await folder.CreateFileAsync($"BetterChat-{DateTime.Now:yyyyMMdd-HHmmss}.png", CreationCollisionOption.GenerateUniqueName);
                // 剪贴板位图统一转成 PNG 再上传。
                var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(source);
                using (var output = await target.OpenAsync(FileAccessMode.ReadWrite))
                {
                    var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, output);
                    encoder.SetSoftwareBitmap(await decoder.GetSoftwareBitmapAsync());
                    await encoder.FlushAsync();
                }
                AddAttachments([target]);
            });
        }
    }

    // 发送：先逐个上传并发送附件（第一条带回复），再发文字。失败的附件留在预览条里，可以再点发送。
    private async Task SendAll()
    {
        if (runtime is not { } session || selectedChat == 0 || sending) return;
        if (attachmentsChat != selectedChat) attachments.Clear();
        if (attachments.Count == 0) { await SendText(); return; }
        long chat = selectedChat; var ct = lifetime.Token;
        sending = true; SendButton.IsEnabled = false;
        try
        {
            long reply = replySeq;
            foreach (var attachment in attachments.ToList())
            {
                Notice.Severity = InfoBarSeverity.Informational; Notice.Message = $"正在上传 {attachment.File.Name}…"; Notice.IsOpen = true;
                using (var stream = await attachment.File.OpenStreamForReadAsync())
                {
                    string mime = attachment.File.ContentType.Length > 0 ? attachment.File.ContentType : "application/octet-stream";
                    var media = await session.UploadMediaAsync(stream, attachment.File.Name, mime, ct);
                    ct.ThrowIfCancellationRequested();
                    if (runtime != session) return;
                    var request = new SendMessageRequest { ChatId = chat, ClientRandomId = RandomId(), ReplyToSeq = reply };
                    request.Segments.Add(attachment.IsImage ? new OutgoingSegment { Image = media } : new OutgoingSegment { File = media });
                    await session.SendMessageAsync(request, ct);
                }
                reply = 0;
                attachments.Remove(attachment);
                if (selectedChat == chat) RenderAttachments();
            }
            if (selectedChat == chat && reply == 0 && replySeq != 0) { replySeq = 0; replies[chat] = 0; UpdateReply(); }
            Notice.IsOpen = false;
        }
        finally { sending = false; SendButton.IsEnabled = true; }
        if (selectedChat == chat && !string.IsNullOrWhiteSpace(Composer.Text)) await SendText();
    }

    // —— 多选 ——
    private bool selecting;
    private void EnterSelection(long? seq = null)
    {
        if (selectedChat == 0 || ChatPanel.Visibility != Visibility.Visible) return;
        selecting = true;
        Messages.SelectionMode = ListViewSelectionMode.Multiple;
        ComposerPanel.Visibility = Visibility.Collapsed; SelectionBar.Visibility = Visibility.Visible;
        if (seq is { } s && Messages.Items.OfType<TimelineEntry>().FirstOrDefault(x => x.Message?.Seq == s) is { } row) Messages.SelectedItems.Add(row);
        UpdateSelectionBar();
    }
    private void ExitSelection()
    {
        if (!selecting) return;
        selecting = false;
        Messages.SelectionMode = ListViewSelectionMode.None;
        SelectionBar.Visibility = Visibility.Collapsed;
        if (selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible) ComposerPanel.Visibility = Visibility.Visible;
    }
    // 时间分隔、灰条、发送中的消息不能选；QQ 一次最多转发 100 条。
    private void MessageSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!selecting) return;
        foreach (var item in e.AddedItems.OfType<TimelineEntry>().Where(x => x.Message is not { State: MessageState.Normal, Kind: not MessageKind.Service }).ToList())
            Messages.SelectedItems.Remove(item);
        UpdateSelectionBar();
    }
    private void UpdateSelectionBar()
    {
        int count = SelectedSequences().Length;
        SelectionCount.Text = count == 0 ? "选择要转发的消息" : $"已选择 {count} 条" + (count > 100 ? "（最多 100 条）" : "");
        SelectionForward.IsEnabled = SelectionBundle.IsEnabled = count is > 0 and <= 100;
    }
    private long[] SelectedSequences() => Messages.SelectedItems.OfType<TimelineEntry>().Select(x => x.Message?.Seq ?? 0).Where(s => s > 0).Distinct().Order().ToArray();
    private async void ForwardSelectedClicked(object sender, RoutedEventArgs e) => await Guard(async () =>
    {
        if (runtime is not { } session || selectedChat == 0) return;
        var sequences = SelectedSequences();
        if (sequences.Length is 0 or > 100) return;
        await Forward(session, selectedChat, sequences, (sender as FrameworkElement)?.Tag as string == "bundle");
        ExitSelection();
    });
    private void CancelSelectionClicked(object sender, RoutedEventArgs e) => ExitSelection();

    // —— 会话内查找 ——
    private void ToggleChatSearch(object sender, RoutedEventArgs e)
    {
        if (ChatSearchBox.Visibility == Visibility.Visible) CloseChatSearch();
        else OpenChatSearch();
    }
    private void OpenChatSearch()
    {
        if (selectedChat == 0 || ChatPanel.Visibility != Visibility.Visible) return;
        ChatSearchBox.Visibility = Visibility.Visible;
        ChatSearchBox.Focus(FocusState.Keyboard);
    }
    private void CloseChatSearch() { ChatSearchBox.Visibility = Visibility.Collapsed; ChatSearchBox.Text = ""; }
    private async void ChatSearchSubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        long chat = selectedChat;
        if (chat == 0 || string.IsNullOrWhiteSpace(args.QueryText)) return;
        await Guard(() => StartSearch(args.QueryText, chat));
    }
    private void ChatSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape) return;
        e.Handled = true; CloseChatSearch(); Composer.Focus(FocusState.Keyboard);
    }
}
