using System.ComponentModel;
using Qqbridge.V1;

namespace BetterChat;

// 中栏列表的一行：会话、联系人、设置项、搜索结果共用一个模板，没有的部分留空即隐藏。
// caption 是右上角的小字（会话的时间、搜索结果的日期）。
public sealed class ListEntry(string title, string subtitle, string caption, object value) : INotifyPropertyChanged
{
    public string Title { get; private set; } = SingleLine(title);
    public string Subtitle { get; private set; } = SingleLine(subtitle);
    public string Caption { get; private set; } = caption;
    public object Value { get; private set; } = value;

    // 预览前的「[草稿]」（强调色）和「发送者：」。
    public string DraftPrefix { get; set; } = "";
    public string SenderPrefix { get; set; } = "";
    // 未读数文字（99+）；免打扰的会话用灰色。
    public string Unread { get; set; } = "";
    public bool UnreadMuted { get; set; }
    public bool Mention { get; set; }
    public bool Reply { get; set; }
    public bool MentionAll { get; set; }
    public bool Pinned { get; set; }
    public bool Muted { get; set; }
    // 设置项用图标代替头像。
    public string Glyph { get; set; } = "";

    public bool HasGlyph => Glyph.Length > 0;
    public bool HasAvatar => Glyph.Length == 0;
    public bool HasSubtitle => Subtitle.Length > 0 || DraftPrefix.Length > 0 || SenderPrefix.Length > 0;
    public bool AccentUnread => Unread.Length > 0 && !UnreadMuted;
    public bool MutedUnread => Unread.Length > 0 && UnreadMuted;

    public event PropertyChangedEventHandler? PropertyChanged;
    public string Key => Value switch { Dialog d => "d:" + d.ChatId, Peer p => $"p:{p.QqAccountId}:{p.Kind}:{p.PeerId}", _ => Title };

    public void Update(ListEntry next)
    {
        Value = next.Value;
        if (Signature == next.Signature) return;
        Title = next.Title; Subtitle = next.Subtitle; Caption = next.Caption;
        DraftPrefix = next.DraftPrefix; SenderPrefix = next.SenderPrefix; Unread = next.Unread; UnreadMuted = next.UnreadMuted;
        Mention = next.Mention; Reply = next.Reply; MentionAll = next.MentionAll; Pinned = next.Pinned; Muted = next.Muted; Glyph = next.Glyph;
        // 空名字表示全部属性都变了：一行只刷新一次绑定，不逐个属性通知。
        PropertyChanged?.Invoke(this, new(string.Empty));
    }

    private string Signature => string.Join('\u001f', Title, Subtitle, Caption, DraftPrefix, SenderPrefix, Unread, UnreadMuted, Mention, Reply, MentionAll, Pinned, Muted, Glyph);
    private static string SingleLine(string text) => text.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
    public override string ToString() => Title;
}
