using Qqbridge.V1;

namespace BetterChat.Core;

public static class MediaPresentation
{
    // 列表只取缩略图或预览图，不因滚动聊天而下载大体积原件。
    public static string PreviewHash(MediaInfo media) => media.ThumbSha256.Length > 0
        ? media.ThumbSha256 : media.PreviewSha256;

    public static string OpenHash(MediaInfo media) => media.PlayableSha256.Length > 0
        ? media.PlayableSha256 : media.Sha256;

    public static string StateText(MediaState state) => state switch
    {
        MediaState.Pending => "正在准备媒体",
        MediaState.OnDemand => "点击加载",
        MediaState.Failed => "加载失败，点击重试",
        MediaState.Expired => "QQ 媒体已过期",
        MediaState.Skipped => "未自动下载，点击加载",
        MediaState.Purged => "原件已清理，预览仍可查看",
        _ => "点击查看"
    };
}
