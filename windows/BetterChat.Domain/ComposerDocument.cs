using Qqbridge.V1;

namespace BetterChat.Core;

// 按 UTF-16 偏移跟踪实体，与 WinUI TextBox 的选区一致；编辑实体内部后退回普通文本。
public sealed class ComposerDocument
{
    private sealed record Entity(int Start, int Length, OutgoingSegment Segment);
    private List<Entity> entities = [];
    public string Text { get; private set; } = "";
    public void UpdateText(string next, int selectionStart, int selectionLength)
    {
        if (next == Text) return;
        int end = selectionStart + selectionLength;
        int replacementLength = next.Length - Text.Length + selectionLength;
        // 重名成员的选区删除必须使用原始位置，不能由相同显示文字反推删掉了谁。
        if (selectionLength > 0 && selectionStart >= 0 && end <= Text.Length && replacementLength >= 0
            && next.StartsWith(Text[..selectionStart], StringComparison.Ordinal)
            && next.EndsWith(Text[end..], StringComparison.Ordinal))
        {
            Replace(selectionStart, selectionLength, next.Substring(selectionStart, replacementLength));
            return;
        }
        UpdateText(next);
    }
    public void UpdateText(string next)
    {
        if (next == Text) return;
        int prefix = 0;
        while (prefix < Text.Length && prefix < next.Length && Text[prefix] == next[prefix]) prefix++;
        int suffix = 0;
        while (suffix < Text.Length - prefix && suffix < next.Length - prefix && Text[^(suffix + 1)] == next[^(suffix + 1)]) suffix++;
        int oldEnd = Text.Length - suffix;
        Replace(prefix, oldEnd - prefix, next.Substring(prefix, next.Length - prefix - suffix));
    }
    private void Replace(int start, int length, string replacement)
    {
        int end = start + length, delta = replacement.Length - length;
        entities = entities.Where(e => e.Start + e.Length <= start || e.Start >= end)
            .Select(e => e.Start >= end ? e with { Start = e.Start + delta } : e).ToList();
        Text = Text.Remove(start, length).Insert(start, replacement);
    }
    public int Insert(int start, int length, string label, OutgoingSegment segment)
    {
        start = Math.Clamp(start, 0, Text.Length); length = Math.Clamp(length, 0, Text.Length - start);
        Replace(start, length, label + " ");
        entities.Add(new(start, label.Length, segment.Clone()));
        entities.Sort((a, b) => a.Start.CompareTo(b.Start));
        return start + label.Length + 1;
    }
    public List<OutgoingSegment> Segments()
    {
        var result = new List<OutgoingSegment>(); int cursor = 0;
        foreach (var entity in entities)
        {
            if (entity.Start > cursor) result.Add(new() { Text = Text[cursor..entity.Start] });
            result.Add(entity.Segment.Clone()); cursor = entity.Start + entity.Length;
        }
        if (cursor < Text.Length) result.Add(new() { Text = Text[cursor..] });
        return result;
    }
    public static ComposerDocument FromSegments(IEnumerable<OutgoingSegment> segments, Func<long, string> name)
    {
        var result = new ComposerDocument();
        foreach (var segment in segments)
        {
            string label = segment.KindCase switch
            {
                OutgoingSegment.KindOneofCase.Text => segment.Text,
                OutgoingSegment.KindOneofCase.MentionUserId => "@" + name(segment.MentionUserId),
                OutgoingSegment.KindOneofCase.MentionAll => "@全体成员",
                OutgoingSegment.KindOneofCase.FaceId => "[表情 " + segment.FaceId + "]",
                _ => "[附件]"
            };
            if (segment.KindCase != OutgoingSegment.KindOneofCase.Text) result.entities.Add(new(result.Text.Length, label.Length, segment.Clone()));
            result.Text += label;
        }
        return result;
    }
}
