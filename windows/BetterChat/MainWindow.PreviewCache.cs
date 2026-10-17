using Microsoft.UI.Xaml.Controls;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowPreviewCache()
    {
        var session = runtime; if (session is null) return;
        var ct = NewPage(); Detail("本机预览缓存", "当前账号的缩略图、头像和表情预览");
        Details.Children.Add(ActionButton("返回存储概览", () => ShowSetting("存储")));
        var usage = await session.GetPreviewCacheUsageAsync(ct); ct.ThrowIfCancellationRequested();
        Details.Children.Add(Text($"已缓存 {usage.Files:N0} 项 · {Bytes((ulong)usage.Bytes)}\n容量上限 {Bytes((ulong)usage.Capacity)} · 临时文件 {Bytes((ulong)usage.TemporaryBytes)}"));
        Details.Children.Add(Text("清理后预览会按需重新下载。消息、草稿和服务端媒体不受影响。正在使用的文件可能暂时无法清理。", 12));
        Details.Children.Add(ActionButton("清理本机预览缓存", async () =>
        {
            ct.ThrowIfCancellationRequested();
            var result = await session.ClearPreviewCacheAsync(ct); ct.ThrowIfCancellationRequested();
            await ShowPreviewCache();
            Notice.Severity = InfoBarSeverity.Informational;
            Notice.Message = $"已清理 {result.RemovedFiles:N0} 项，释放 {Bytes((ulong)result.RemovedBytes)}；跳过 {result.SkippedFiles:N0} 个使用中或不可删除的文件。";
            Notice.IsOpen = true;
        }));
    }
}
