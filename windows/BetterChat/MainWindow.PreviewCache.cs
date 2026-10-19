using Microsoft.UI.Xaml.Controls;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowPreviewCache()
    {
        var session = runtime; if (session is null) return;
        var ct = NewPage(); Detail("本机预览缓存", "当前账号的缩略图、头像和表情预览");
        var usage = await session.GetPreviewCacheUsageAsync(ct); ct.ThrowIfCancellationRequested();
        Details.Children.Add(Hero(GlyphTile("\uE8B7"), Bytes((ulong)usage.Bytes), $"已缓存 {usage.Files:N0} 项 · 容量上限 {Bytes((ulong)usage.Capacity)}", $"临时文件 {Bytes((ulong)usage.TemporaryBytes)}"));
        var clear = new Button { Content = "清理" };
        Details.Children.Add(Card("清理本机预览缓存", "预览会按需重新下载；消息、草稿和服务端媒体不受影响，正在使用的文件可能暂时清不掉", "\uE74D", clear));
        clear.Click += async (_, _) => await Guard(async () =>
        {
            ct.ThrowIfCancellationRequested();
            var result = await session.ClearPreviewCacheAsync(ct); ct.ThrowIfCancellationRequested();
            await ShowPreviewCache();
            Notice.Severity = InfoBarSeverity.Informational;
            Notice.Message = $"已清理 {result.RemovedFiles:N0} 项，释放 {Bytes((ulong)result.RemovedBytes)}；跳过 {result.SkippedFiles:N0} 个使用中或不可删除的文件。";
            Notice.IsOpen = true;
        });
    }
}
