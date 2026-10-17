using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace BetterChat.Application;

// 聊天页的展示规则，和 iOS MessageRow 对齐，放在应用层便于测试：时间分隔、发送者合并、链接识别、卡片解析。
public static partial class ChatPresentation
{
    private static readonly CultureInfo Chinese = CultureInfo.GetCultureInfo("zh-CN");

    // 和上一条隔了 5 分钟以上才显示时间（iOS showsTime）。
    public const long TimeGapSeconds = 300;

    public readonly record struct TimelineItem(long Time, long SenderId, bool IsUserMessage);
    public readonly record struct TimelineLayout(bool ShowsTime, bool ShowsSender);

    // 群里别人发的：第一条、隔了时间分隔、或者和上一条不是同一个人发的，才显示名字和头像（iOS showsSender）。
    // 上一条是灰条 / 事件时也重新显示。私聊和自己发的不显示。
    public static TimelineLayout[] Layout(IReadOnlyList<TimelineItem> items, bool group, IReadOnlySet<long> ownUsers)
    {
        var result = new TimelineLayout[items.Count];
        for (int i = 0; i < items.Count; i++)
        {
            var item = items[i];
            bool time = i == 0 || item.Time - items[i - 1].Time > TimeGapSeconds;
            bool sender = group && item.IsUserMessage && !ownUsers.Contains(item.SenderId)
                && (time || !items[i - 1].IsUserMessage || items[i - 1].SenderId != item.SenderId);
            result[i] = new(time, sender);
        }
        return result;
    }

    // 时间分隔条：今天「14:05」、昨天「昨天 14:05」、一周内「星期一 14:05」、今年「10月12日 14:05」、更早带年份。
    public static string TimeHeader(long unix, DateTimeOffset now, TimeZoneInfo zone)
    {
        var time = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeSeconds(unix), zone);
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        int days = (today - time.Date).Days;
        string clock = time.ToString("HH:mm", Chinese);
        if (days <= 0) return clock;
        if (days == 1) return "昨天 " + clock;
        if (days < 7) return Chinese.DateTimeFormat.GetDayName(time.DayOfWeek) + " " + clock;
        if (time.Year == today.Year) return time.ToString("M月d日 ", Chinese) + clock;
        return time.ToString("yyyy年M月d日 ", Chinese) + clock;
    }

    public enum TextRunKind { Text, Link, Number }
    public readonly record struct TextRun(TextRunKind Kind, string Text, string Target);

    [GeneratedRegex(@"(?:https?://|www\.)[^\s<>""'，。！？、；：（）【】《》]+", RegexOptions.IgnoreCase)]
    private static partial Regex LinkPattern();
    [GeneratedRegex(@"(?<![0-9A-Za-z])\d{5,}(?![0-9A-Za-z])")]
    private static partial Regex NumberPattern();

    // 链接可点；5 位以上的数字可点（QQ 号、手机号，iOS Linkify）。链接末尾的英文标点不算链接。
    public static IReadOnlyList<TextRun> Linkify(string text)
    {
        var marks = new List<(int Start, int Length, TextRunKind Kind, string Target)>();
        foreach (Match m in LinkPattern().Matches(text))
        {
            string value = m.Value.TrimEnd('.', ',', ';', ':', '!', '?', ')', ']');
            if (value.Length == 0) continue;
            marks.Add((m.Index, value.Length, TextRunKind.Link, value.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + value : value));
        }
        foreach (Match m in NumberPattern().Matches(text))
            if (!marks.Any(x => m.Index < x.Start + x.Length && x.Start < m.Index + m.Length))
                marks.Add((m.Index, m.Length, TextRunKind.Number, m.Value));
        marks.Sort((a, b) => a.Start.CompareTo(b.Start));
        var runs = new List<TextRun>();
        int at = 0;
        foreach (var (start, length, kind, target) in marks)
        {
            if (start > at) runs.Add(new(TextRunKind.Text, text[at..start], ""));
            runs.Add(new(kind, text.Substring(start, length), target));
            at = start + length;
        }
        if (at < text.Length) runs.Add(new(TextRunKind.Text, text[at..], ""));
        return runs;
    }

    // 小程序 / 分享卡片（iOS AppCard.parse）：来源、标题、简介、封面和能用浏览器打开的链接。解析不出时返回 null。
    public sealed record AppCard(string Source, string Title, string Description, string Preview, string Url);

    public static AppCard? ParseAppCard(string json, string app)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("meta", out var meta) || meta.ValueKind != JsonValueKind.Object) return null;
            JsonElement? detail = null;
            foreach (var p in meta.EnumerateObject()) if (p.Value.ValueKind == JsonValueKind.Object) { detail = p.Value; break; }
            if (detail is not { } d) return null;
            string Str(params string[] keys)
            {
                foreach (var k in keys) if (d.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s) return s;
                return "";
            }
            string title = Str("title"), desc = Str("desc", "summary", "forwardMessage");
            if (title.Length == 0 && desc.Length == 0) return null;
            // 小程序的 title 是小程序名（哔哩哔哩），desc 才是内容标题。m.q.qq.com 的小程序链接浏览器打不开，不用。
            bool mini = d.TryGetProperty("appid", out _);
            string url = new[] { Str("qqdocurl"), Str("jumpUrl", "jumpurl"), Str("url") }.Select(WebLink)
                .FirstOrDefault(u => u.Length > 0 && !u.Contains("://m.q.qq.com", StringComparison.OrdinalIgnoreCase)) ?? "";
            string prompt = root.TryGetProperty("prompt", out var pr) && pr.ValueKind == JsonValueKind.String ? pr.GetString() ?? "" : "";
            string source = mini ? title : Str("tag") is { Length: > 0 } tag ? tag : prompt.Length > 0 ? prompt : app;
            return new(source, mini ? desc : title, mini ? "" : desc, WebLink(Str("preview", "cover")), url);
        }
        catch (JsonException) { return null; }
    }

    // 卡片解析不出时的一句话（iOS CardText）。
    public static string CardText(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("prompt", out var p) && p.ValueKind == JsonValueKind.String && p.GetString() is { Length: > 0 } prompt) return prompt;
            if (root.TryGetProperty("meta", out var meta) && meta.ValueKind == JsonValueKind.Object)
                foreach (var v in meta.EnumerateObject())
                    if (v.Value.ValueKind == JsonValueKind.Object)
                        foreach (var key in new[] { "title", "desc" })
                            if (v.Value.TryGetProperty(key, out var t) && t.ValueKind == JsonValueKind.String && t.GetString() is { Length: > 0 } s) return "[卡片] " + s;
            return "[卡片]";
        }
        catch (JsonException) { return "[卡片消息]"; }
    }

    // 只保留浏览器能打开的 http(s) 链接；mqqapi:// 这类 QQ 专用协议丢掉；http 升到 https。
    public static string WebLink(string value)
    {
        if (value.Length == 0) return "";
        if (value.Contains("://") && !value.StartsWith("http", StringComparison.OrdinalIgnoreCase)) return "";
        string full = value.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ? value
            : value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ? "https://" + value[7..] : "https://" + value;
        return Uri.TryCreate(full, UriKind.Absolute, out var uri) && uri.Host.Length > 0 ? uri.AbsoluteUri : "";
    }

    // 服务事件（进群、退群、禁言、戳一戳、通话……）的一句话，和 iOS EventText.describe 同一套文案。
    // actor / target 是已经换成显示名的人；没有时传空串。
    public static string EventText(string kind, string dataJson, string actor, string target, bool actorIsTarget)
    {
        JsonDocument? doc = null;
        try
        {
            try { doc = JsonDocument.Parse(dataJson.Length > 0 ? dataJson : "{}"); } catch (JsonException) { }
            var data = doc?.RootElement ?? default;
            string Str(string key) => data.ValueKind == JsonValueKind.Object && data.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
            double Num(string key) => data.ValueKind == JsonValueKind.Object && data.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;
            bool Bool(string key) => data.ValueKind == JsonValueKind.Object && data.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
            string either = target.Length > 0 ? target : actor;
            switch (kind)
            {
                case "member_join":
                    // 邀请进群写上邀请人；同意申请时 actor 是同意的管理员，不写。
                    return Str("via") == "invite" && actor.Length > 0 && target.Length > 0 && !actorIsTarget ? $"{actor} 邀请 {target} 加入了群聊" : $"{either} 加入了群聊";
                case "member_leave":
                    return Str("how") is "kick" or "kick_me" && actor.Length > 0 && target.Length > 0 ? $"{target} 被 {actor} 移出了群聊" : $"{either} 离开了群聊";
                case "admin_set": return $"{target} 成为管理员";
                case "admin_unset": return $"{target} 不再是管理员";
                case "mute":
                    if (target.Length == 0) return $"{actor} 开启了全员禁言";
                    double secs = Num("duration");
                    return secs > 0 ? $"{target} {(actor.Length == 0 ? "被" : $"被 {actor} ")}禁言 {Remaining(secs)}" : $"{target} 被禁言";
                case "unmute": return target.Length == 0 ? $"{actor} 关闭了全员禁言" : $"{target} 被{(actor.Length == 0 ? "" : $" {actor} ")}解除禁言";
                case "card_change": return Str("cardNew") is { Length: > 0 } card ? $"{target} 修改群名片为「{card}」" : $"{target} 清空了群名片";
                case "title": return $"{target} 获得了头衔 {Str("title")}";
                case "group_name": return $"{actor} 修改群名为 {Str("name")}";
                case "essence_add": return $"{actor} 设置了一条精华消息";
                case "essence_remove": return $"{actor} 移除了一条精华消息";
                case "poke": return $"{actor} 戳了戳 {target}";
                case "friend_add": return "你们已成为好友";
                case "group_file": return $"{actor} 上传了文件 {Str("name")}";
                case "call":
                    string media = Str("media") == "video" ? "视频" : "语音";
                    bool answered = Str("result") == "answered";
                    string length = Duration((int)Num("durationSec"));
                    if (Bool("group")) return answered ? $"群{media}通话 {length}" : $"{actor} 发起的群{media}通话已结束";
                    return answered ? $"{media}通话 {length}" : Str("result") == "declined" ? $"已拒接{media}通话" : $"未接{media}通话";
                case "gray_tip": return Str("text") is { Length: > 0 } tip ? tip : "系统消息";
                default: return $"[{kind}]";
            }
        }
        finally { doc?.Dispose(); }
    }

    public static string Duration(int seconds) => $"{seconds / 60}:{seconds % 60:00}";

    // 禁言之类的时长：「29 天 23 小时」「2 小时 3 分」「5 分 12 秒」。
    public static string Remaining(double seconds)
    {
        int t = Math.Max(0, (int)Math.Ceiling(seconds));
        int d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60, s = t % 60;
        if (d > 0) return h > 0 ? $"{d} 天 {h} 小时" : $"{d} 天";
        if (h > 0) return m > 0 ? $"{h} 小时 {m} 分" : $"{h} 小时";
        return m > 0 ? $"{m} 分 {s} 秒" : $"{s} 秒";
    }

    // 还不支持的元素（iOS UnsupportedItem）：红包、长消息、没认出的灰条，其余写出元素名。
    public sealed record UnsupportedCard(string Title, string Subtitle, string Glyph);

    public static UnsupportedCard Unsupported(string original, string dataJson)
    {
        JsonElement root = default;
        JsonDocument? doc = null;
        try { doc = JsonDocument.Parse(dataJson.Length > 0 ? dataJson : "{}"); root = doc.RootElement; }
        catch (JsonException) { }
        try
        {
            static string? Str(JsonElement e, params string[] path)
            {
                foreach (var p in path)
                {
                    if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(p, out e)) return null;
                }
                return e.ValueKind == JsonValueKind.String && e.GetString() is { Length: > 0 } s ? s : null;
            }
            switch (original)
            {
                case "nt:9":
                    return new("QQ红包", Str(root, "walletElement", "receiver", "title") ?? Str(root, "walletElement", "receiver", "notice") ?? "在 QQ 里领取", "");
                case "nt:13":
                    string xml = Str(root, "structLongMsgElement", "xmlContent") ?? "";
                    var summary = Regex.Match(xml, "<summary[^>]*>([^<]+)</summary>");
                    var brief = Regex.Match(xml, "brief=\"([^\"]+)\"");
                    return new("长消息", summary.Success ? summary.Groups[1].Value : brief.Success ? brief.Groups[1].Value : "完整内容只能在 QQ 里看", "");
                case "nt:8":
                    return new("灰色提示", "还没认出来", "");
                default:
                    string? element = root.ValueKind == JsonValueKind.Object
                        ? root.EnumerateObject().Select(p => p.Name).Where(n => n.EndsWith("Element", StringComparison.Ordinal) && n != "extBufForUI")
                            .Where(n => root.GetProperty(n).ValueKind != JsonValueKind.Null).OrderBy(n => n, StringComparer.Ordinal).FirstOrDefault()
                        : null;
                    return new("暂不支持的消息", element ?? original, "");
            }
        }
        finally { doc?.Dispose(); }
    }
}
