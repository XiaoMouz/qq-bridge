using Qqbridge.V1;

namespace BetterChat.Core;

public static class ForwardValidation
{
    public static ForwardMessagesRequest Normalize(ForwardMessagesRequest request)
    {
        static bool Valid(long value) => value > 0 && value <= (1L << 53) - 1;
        if (!Valid(request.FromChatId) || request.Seqs.Any(s => !Valid(s)) || request.ToChatIds.Any(c => !Valid(c)))
            throw new ArgumentException("转发来源、消息序号或目标会话无效。");
        var copy = new ForwardMessagesRequest { FromChatId = request.FromChatId, Bundle = request.Bundle };
        copy.Seqs.AddRange(request.Seqs.Distinct().Order());
        copy.ToChatIds.AddRange(request.ToChatIds.Distinct());
        // 后端按去重后的数量限制；保持相同语义，避免重复目标重复提交。
        if (copy.Seqs.Count is < 1 or > 100 || copy.ToChatIds.Count is < 1 or > 20)
            throw new ArgumentException("每次可转发 1 至 100 条消息到 1 至 20 个会话。");
        return copy;
    }
}
