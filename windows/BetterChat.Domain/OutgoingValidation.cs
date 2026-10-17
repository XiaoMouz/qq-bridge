using Qqbridge.V1;

namespace BetterChat.Core;

public static class OutgoingValidation
{
    private const long SafeMax = (1L << 53) - 1;
    // 对照 domain/outgoing.ts 与 server/api/convert.ts；长度按 UTF-16，与 JS string.length 一致。
    public static void Validate(SendMessageRequest request)
    {
        if (request.ChatId is <= 0 or > SafeMax || request.ClientRandomId is <= 0 or > SafeMax || request.ReplyToSeq is < 0 or > SafeMax)
            throw new ArgumentException("会话、消息标识或回复序号无效。");
        if (request.Segments.Count is < 1 or > 50) throw new ArgumentException("消息必须包含 1 至 50 个内容段。");
        int textLength = 0;
        bool standalone = false;
        foreach (var segment in request.Segments)
        {
            OutgoingMedia? media = null;
            switch (segment.KindCase)
            {
                case OutgoingSegment.KindOneofCase.Text:
                    if (segment.Text.Length == 0) throw new ArgumentException("文字段不能为空。");
                    textLength += segment.Text.Length;
                    if (textLength > 5000) throw new ArgumentException("消息文字总长度不能超过 5000。");
                    break;
                case OutgoingSegment.KindOneofCase.MentionUserId:
                    if (segment.MentionUserId is <= 0 or > SafeMax) throw new ArgumentException("提及用户 ID 无效。");
                    break;
                case OutgoingSegment.KindOneofCase.MentionAll: break;
                case OutgoingSegment.KindOneofCase.FaceId:
                    if (segment.FaceId.Length is < 1 or > 6 || !segment.FaceId.All(c => c is >= '0' and <= '9'))
                        throw new ArgumentException("QQ 表情 ID 必须是 1 至 6 位数字。");
                    break;
                case OutgoingSegment.KindOneofCase.Image: media = segment.Image; break;
                case OutgoingSegment.KindOneofCase.Record: media = segment.Record; standalone = true; break;
                case OutgoingSegment.KindOneofCase.Video: media = segment.Video; standalone = true; break;
                case OutgoingSegment.KindOneofCase.File:
                    media = segment.File; standalone = true;
                    if (string.IsNullOrWhiteSpace(media.Name) || media.Name.Length > 255 || media.Name.IndexOfAny(['/', '\\', '\0']) >= 0)
                        throw new ArgumentException("文件名不能为空、不能超过 255 字符或包含路径分隔符。");
                    break;
                default:
                    // 合并转发是发件箱只读内容，必须通过 ForwardMessages 生成。
                    throw new ArgumentException("该内容不能通过普通消息接口发送。");
            }
            if (media is not null && (media.Sha256.Length != 64 || !media.Sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')))
                throw new ArgumentException("媒体需要有效的小写 SHA-256。");
        }
        if (standalone && (request.Segments.Count != 1 || request.ReplyToSeq != 0))
            throw new ArgumentException("文件、语音和视频必须单独发送，不能携带回复。");
    }
}
