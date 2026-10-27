using Microsoft.UI.Xaml;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    // 群文件 / 文件夹 / 共享文件的一行：和设置页同一种可点卡片（图标、名称、大小与上传者），右键出操作菜单。
    // 下载和打开期间右侧转一个进度环，不再写「正在下载…」；原来是透明按钮，点了以后整行只是变灰，看不出在下载。
    private FrameworkElement FileRow(string glyph, string title, string detail, Func<Task> open)
    {
        var busy = new ProgressRing { IsActive = false, Width = 16, Height = 16, Visibility = Visibility.Collapsed };
        var card = new ClickableSettingsCard { IsClickEnabled = true, Header = title, Description = detail, HeaderIcon = new FontIcon { Glyph = glyph }, Content = busy };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(card, title);
        async void Run()
        {
            if (busy.IsActive) return;
            busy.IsActive = true; busy.Visibility = Visibility.Visible; card.IsClickEnabled = false;
            try { await Guard(open); }
            finally { busy.IsActive = false; busy.Visibility = Visibility.Collapsed; card.IsClickEnabled = true; }
        }
        card.Click += (_, _) => Run(); card.Invoked = Run;
        return card;
    }
    private static string FileGlyph(string name) => Path.GetExtension(name).ToLowerInvariant() switch
    {
        ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" => "\uEB9F",
        ".mp4" or ".mov" or ".mkv" or ".avi" or ".webm" => "\uE714",
        ".mp3" or ".wav" or ".flac" or ".m4a" or ".ogg" => "\uE8D6",
        ".zip" or ".rar" or ".7z" or ".tar" or ".gz" => "\uF012",
        ".txt" or ".md" or ".log" or ".json" => "\uE8A5",
        ".pdf" or ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx" => "\uE8A5",
        ".exe" or ".msi" or ".apk" => "\uECAA",
        _ => "\uE7C3"
    };

    private FrameworkElement GroupFileButton(Peer group, string folder, GroupFile file, GroupFilesViewModel vm, CancellationToken ct)
    {
        var session = runtime ?? throw new InvalidOperationException("账号已断开。");
        var currentApi = session.Api;
        string detail = Bytes(file.Size) + (file.UploaderName.Length > 0 ? " · " + file.UploaderName : "") + (file.ModifyTime > 0 ? " · " + Time(file.ModifyTime) : "");
        var button = FileRow(FileGlyph(file.Name), file.Name, detail, async () =>
        {
            var result = await session.FetchGroupFileAsync(new() { GroupId = group.PeerId, FileId = file.Id, Busid = file.Busid, Name = file.Name, Size = file.Size }, ct);
            ct.ThrowIfCancellationRequested();
            var uri = await MediaUri(currentApi, result.Sha256, ct);
            ct.ThrowIfCancellationRequested(); await Windows.System.Launcher.LaunchUriAsync(uri);
        });
        var menu = new MenuFlyout();
        void Item(string label, Func<Task> action)
        {
            var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await Guard(async () => { ct.ThrowIfCancellationRequested(); await action(); }); menu.Items.Add(item);
        }
        Item("重命名", async () =>
        {
            var input = new TextBox { Text = file.Name, Header = "文件名", MinWidth = 280 };
            var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "重命名群文件", Content = input, PrimaryButtonText = "保存", CloseButtonText = "取消" };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            if (string.IsNullOrWhiteSpace(input.Text)) throw new ArgumentException("文件名不能为空。");
            await RunGroupFileOperation(group, vm, vm.RenameFile, new GroupFileRename(file.Id, input.Text), ct);
        });
        Item("移动到…", async () =>
        {
            var root = await session.ListGroupFilesAsync(new() { GroupId = group.PeerId }, ct); ct.ThrowIfCancellationRequested();
            var destinations = new List<GroupFolder> { new() { Id = "", Name = "根目录" } }; destinations.AddRange(root.Folders);
            var chooser = new ComboBox { ItemsSource = destinations.Where(f => f.Id != folder).ToList(), DisplayMemberPath = "Name", MinWidth = 280 };
            var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "移动群文件", Content = chooser, PrimaryButtonText = "移动", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
            chooser.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = chooser.SelectedItem is GroupFolder;
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || chooser.SelectedItem is not GroupFolder target) return;
            await RunGroupFileOperation(group, vm, vm.MoveFile, new GroupFileMove(file.Id, target.Id), ct,
                result => string.Join("\n", result.Failures.Select(f => f.Reason)));
        });
        Item("删除", async () =>
        {
            var confirm = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "删除群文件？", Content = $"将从 QQ 群文件中删除“{file.Name}”。", PrimaryButtonText = "删除", CloseButtonText = "取消" };
            if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
            await RunGroupFileOperation(group, vm, vm.DeleteFile, new GroupFileDeletion(file.Id), ct,
                result => string.Join("\n", result.Failures.Select(f => f.Reason)));
        });
        button.ContextFlyout = menu; return button;
    }

    private async Task CreateGroupFolder(Peer group, GroupFilesViewModel vm, CancellationToken ct)
    {
        var name = new TextBox { Header = "文件夹名称", MinWidth = 280 };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "新建群文件夹", Content = name, PrimaryButtonText = "创建", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(name.Text);
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await RunGroupFileOperation(group, vm, vm.CreateFolder, new GroupFolderCreation(name.Text), ct);
    }

    private bool groupMutationBusy;
    private async Task RunGroupFileOperation<TRequest, TResponse>(Peer group, GroupFilesViewModel vm,
        RpcOperationViewModel<TRequest, TResponse> operation, TRequest request, CancellationToken ct,
        Func<TResponse, string>? failure = null) where TRequest : class where TResponse : class
    {
        ct.ThrowIfCancellationRequested();
        if (groupMutationBusy || featurePage != vm) return;
        groupMutationBusy = true;
        try
        {
            bool success = await operation.ExecuteAsync(request, ct);
            ct.ThrowIfCancellationRequested();
            if (featurePage != vm) return;
            string? error = success && operation.Result is { } result ? failure?.Invoke(result)
                : operation.Error ?? "操作未完成，结果待确认。";
            // 网络错误也可能已经改变 QQ 文件 ID，先重新列目录，再允许下一次操作。
            await ShowGroup(group, "群文件", vm.FolderId);
            if (!string.IsNullOrWhiteSpace(error)) throw new IOException(error);
        }
        finally { groupMutationBusy = false; }
    }
}
