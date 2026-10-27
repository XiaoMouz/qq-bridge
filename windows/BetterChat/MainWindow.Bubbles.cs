using BetterChat.Application;
using BetterChat.Application.ViewModels;
using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using ProtoMessage = Qqbridge.V1.Message;

namespace BetterChat;

// 聊天气泡（对齐 iOS MessageRow）：头像 / 名字按连续发送合并，引用块、@ 徽章、链接、卡片、回应条、时间在气泡右下角。
public sealed partial class MainWindow
{
    // 当前历史窗口里的消息，按 seq 查引用的原文。
    private Dictionary<long, ProtoMessage> timelineMessages = [];
    // 自己的气泡是强调色底，里面的引用块、卡片用一层半透明白，别的气泡用浅灰。
    private static readonly Brush OnAccentOverlay = new SolidColorBrush(Windows.UI.Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));

    private static T Res<T>(string key) where T : class => (T)Microsoft.UI.Xaml.Application.Current.Resources[key];

    // 代码里创建控件用的主题画刷。Application.Current.Resources[...] 只按应用级主题（浅色）取值，不跟窗口上设置的
    // 深色 / 高对比度走，深色模式下自己的气泡还是浅色主题的深蓝、图片下的时间变成深灰看不见（2026-10-19 实测）。
    // 这里按窗口实际主题到主题字典里找，找不到再退回应用资源。
    private static string themeKey = "Light";
    private static Brush Brush(string key)
    {
        foreach (var dictionary in Microsoft.UI.Xaml.Application.Current.Resources.MergedDictionaries.Prepend(Microsoft.UI.Xaml.Application.Current.Resources))
        {
            if (dictionary.ThemeDictionaries.TryGetValue(themeKey, out var theme) && theme is ResourceDictionary resources && resources.TryGetValue(key, out var value) && value is Brush brush)
                return brush;
            foreach (var nested in dictionary.MergedDictionaries)
                if (nested.ThemeDictionaries.TryGetValue(themeKey, out var nestedTheme) && nestedTheme is ResourceDictionary nestedResources && nestedResources.TryGetValue(key, out var nestedValue) && nestedValue is Brush nestedBrush)
                    return nestedBrush;
        }
        return Res<Brush>(key);
    }

    // 主题字典的键：XamlControlsResources 里深色叫 Default。高对比度优先。
    private void UpdateThemeKey()
    {
        bool contrast = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
        themeKey = contrast ? "HighContrast" : Root.ActualTheme == ElementTheme.Dark ? "Default" : "Light";
    }

    // 主题变了：代码创建的气泡、页面用的是旧画刷，重建时间线并重新显示当前页。
    private void ThemeChanged()
    {
        string previous = themeKey;
        UpdateThemeKey();
        if (previous == themeKey) return;
        timelineRenderRevision++; messageSignature = ""; messageViews.Clear(); Messages.Items.Clear();
        if (selectedChat != 0 && ChatPanel.Visibility == Visibility.Visible) _ = Guard(RenderMessages);
        else if (navigator.Current is { } page) _ = Guard(page.Show);
    }

    private static FrameworkElement TimeHeaderView(long time) => new TextBlock
    {
        Text = ChatPresentation.TimeHeader(time, DateTimeOffset.Now, TimeZoneInfo.Local),
        Style = Res<Style>("TertiaryCaptionTextBlockStyle"), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 4)
    };

    // 灰条：居中的浅底胶囊。
    private static FrameworkElement NoticeView(IEnumerable<Inline> inlines)
    {
        var paragraph = new Paragraph();
        foreach (var inline in inlines) paragraph.Inlines.Add(inline);
        var text = new RichTextBlock { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontSize = 12, Foreground = Brush("TextFillColorSecondaryBrush") };
        text.Blocks.Add(paragraph);
        return new Border { Style = Res<Style>("NoticeBorderStyle"), Child = text };
    }

    // QQ 灰色提示（撤回、进群、拍一拍……）：文字 + 人名，人名可点开资料（iOS Notice）。
    private FrameworkElement ServiceNotice(ProtoMessage m)
    {
        var inlines = new List<Inline>();
        foreach (var s in m.Segments)
        {
            if (s.Text is { } t) inlines.Add(new Run { Text = t.Text });
            else if (s.Mention is { } at)
            {
                string name = at.Name.Length > 0 ? at.Name : PeerName(at.UserId, Scene.Friend);
                if (peerIndex.GetValueOrDefault((at.UserId, false)) is { } person)
                {
                    var link = new Hyperlink { UnderlineStyle = UnderlineStyle.None };
                    link.Inlines.Add(new Run { Text = name });
                    link.Click += async (_, _) => await Guard(() => Go(ProfileKey(person), () => { NewPage(); ShowProfile(person); }));
                    inlines.Add(link);
                }
                else inlines.Add(new Run { Text = name, Foreground = Brush("AccentTextFillColorPrimaryBrush") });
            }
        }
        if (inlines.Count == 0) inlines.Add(new Run { Text = m.Text });
        return NoticeView(inlines);
    }

    // 服务事件：文案里提到的人（发起人、对象）按出现顺序标成可点的名字（iOS EventText.people）。
    private FrameworkElement EventNotice(ChatEvent e)
    {
        string text = EventText(e);
        var inlines = new List<Inline>();
        int at = 0;
        foreach (long id in new[] { e.ActorId, e.TargetId }.Where(id => id != 0).Distinct())
        {
            string name = PeerName(id, Scene.Friend);
            int index = name.Length == 0 ? -1 : text.IndexOf(name, at, StringComparison.Ordinal);
            if (index < 0 || peerIndex.GetValueOrDefault((id, false)) is not { } person) continue;
            if (index > at) inlines.Add(new Run { Text = text[at..index] });
            var link = new Hyperlink { UnderlineStyle = UnderlineStyle.None };
            link.Inlines.Add(new Run { Text = name });
            link.Click += async (_, _) => await Guard(() => Go(ProfileKey(person), () => { NewPage(); ShowProfile(person); }));
            inlines.Add(link);
            at = index + name.Length;
        }
        if (at < text.Length) inlines.Add(new Run { Text = text[at..] });
        return NoticeView(inlines);
    }

    // 还没确认的本地消息：失败可重试。
    private FrameworkElement PendingView(SendMessageRequest pending)
    {
        var retry = RetryButton(); retry.Click += async (_, _) => await Guard(() => Submit(pending));
        // 本地已入库、服务端还没确认：可能正在发，也可能上次请求断了，所以转圈的同时给重试（幂等 ID 不会重复发送）。
        return PendingBubble(OutgoingPreview(pending.Segments), failed: false, "", retry);
    }
    // 发件箱里的消息：等待中只转一个小进度环；失败标红，转发的只能从原消息重发。
    private FrameworkElement OutboxView(OutboxEntry o)
    {
        if (o.State != OutboxState.Failed) return PendingBubble(OutgoingPreview(o.Segments), failed: false, "", null);
        if (o.Segments.Any(s => s.KindCase == OutgoingSegment.KindOneofCase.Forward))
            return PendingBubble(OutgoingPreview(o.Segments), failed: true, o.Error, new TextBlock { Text = "请从原消息重新转发", Style = Res<Style>("CaptionTextBlockStyle"), Foreground = Brush("SystemFillColorCriticalBrush") });
        var retry = RetryButton();
        retry.Click += async (_, _) => await Guard(() => { var r = new SendMessageRequest { ChatId = o.ChatId, ClientRandomId = o.ClientRandomId, ReplyToSeq = o.ReplyToSeq }; r.Segments.Add(o.Segments); return Submit(r); });
        return PendingBubble(OutgoingPreview(o.Segments), failed: true, o.Error, retry);
    }
    private static Button RetryButton()
    {
        var retry = new Button { Content = new FontIcon { Glyph = "\uE72C", FontSize = 12 }, Padding = new Thickness(6, 4, 6, 4), MinWidth = 0, MinHeight = 0 };
        ToolTipService.SetToolTip(retry, "重试"); AutomationProperties.SetName(retry, "重试发送");
        return retry;
    }

    // 和自己的气泡同一侧、半透明。状态只用图标表达（同 iOS / Mac：发送中转圈、失败红色感叹号），失败原因放在提示里。
    private static FrameworkElement PendingBubble(string text, bool failed, string error, FrameworkElement? action)
    {
        var bubble = new Border
        {
            Child = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            Padding = Res<object>("BubblePadding") is Thickness p ? p : new Thickness(12, 8, 12, 6), CornerRadius = Res<object>("OverlayCornerRadius") is CornerRadius r ? r : new CornerRadius(8),
            Background = Brush("SubtleFillColorSecondaryBrush"), BorderBrush = Brush(failed ? "SystemFillColorCriticalBrush" : "CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            MaxWidth = (double)Microsoft.UI.Xaml.Application.Current.Resources["BubbleMaxWidth"], Opacity = failed ? 1 : 0.7
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 2, 0, 2) };
        if (action is not null) { action.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(action); }
        if (failed)
        {
            var mark = new FontIcon { Glyph = "\uEA39", FontSize = 16, Foreground = Brush("SystemFillColorCriticalBrush"), VerticalAlignment = VerticalAlignment.Center };
            if (error.Length > 0) ToolTipService.SetToolTip(mark, error);
            AutomationProperties.SetName(mark, error.Length > 0 ? "发送失败：" + error : "发送失败");
            row.Children.Add(mark);
        }
        else row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(bubble);
        return row;
    }

    private FrameworkElement MessageView(ProtoMessage m, bool includeActions = true, bool showSender = false)
    {
        if (m.Kind == MessageKind.Service) return ServiceNotice(m);
        var owner = runtime;
        var pageToken = pageTask?.Token ?? lifetime.Token;
        Task OnOriginalPage(Func<Task> action) => owner is not null && runtime == owner && !pageToken.IsCancellationRequested ? action() : Task.CompletedTask;
        bool own = runtime?.OwnUsers.Contains(m.SenderId) == true;
        bool group = dialogIndex.GetValueOrDefault(m.ChatId)?.Scene == Scene.Group;
        // 只有一张图 / 一个视频 / 一个表情包：不套气泡底色，画面本身就是内容（时间写在下面）。
        bool mediaOnly = m.ReplyToSeq == 0 && m.Segments.Count == 1 && m.Segments[0] is { } only
            && (only.Image is not null || only.MarketFace is not null || only.Video is not null);
        var foreground = mediaOnly ? Brush("TextFillColorSecondaryBrush") : own ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("TextFillColorPrimaryBrush");
        var inner = own ? OnAccentOverlay : Brush("SubtleFillColorSecondaryBrush");

        FrameworkElement content;
        // 气泡里可选中文字的控件：右键时要打开消息菜单，而不是它们自带的「全选」文字菜单。
        var texts = new List<FrameworkElement>();
        if (m.ReplyToSeq == 0 && JumboFaces(m) is { } jumbo) content = jumbo;
        else
        {
            var body = new StackPanel { Spacing = 6 };
            if (m.ReplyToSeq > 0) body.Children.Add(ReplyQuote(m, own, inner, OnOriginalPage));
            Paragraph? paragraph = null;
            void Inline(Inline item)
            {
                if (paragraph is null)
                {
                    paragraph = new Paragraph();
                    var rich = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontSize = 14, Foreground = foreground };
                    texts.Add(rich);
                    rich.Blocks.Add(paragraph); body.Children.Add(rich);
                }
                paragraph.Inlines.Add(item);
            }
            foreach (var s in m.Segments)
            {
                if (s.Text is null && s.Mention is null && s.MentionAll is null && s.Face is null) paragraph = null;
                if (s.Text is { } t) foreach (var run in TextInlines(t.Text, own)) Inline(run);
                else if (s.Mention is { } at) Inline(new InlineUIContainer { Child = MentionChip(at, own, OnOriginalPage) });
                else if (s.MentionAll is not null) Inline(new Run { Text = "@全体成员 ", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                else if (s.Face is { } f)
                {
                    if (FaceImage(f.FaceId) is { } picture) Inline(new InlineUIContainer { Child = picture });
                    else Inline(new Run { Text = "[" + (f.Name.Length > 0 ? f.Name : "表情 " + f.FaceId) + "]" });
                }
                else if (s.Markdown is { } markdown)
                {
                    var block = new TextBlock { Text = markdown.Content, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Foreground = foreground };
                    texts.Add(block); body.Children.Add(block);
                }
                else if (s.Record is { } record && Media(s) is { } voice) body.Children.Add(VoiceView(m, record, voice, own, foreground, pageToken));
                else if (Media(s) is { } media)
                {
                    string label = s.File?.Name ?? (s.Image is not null ? "图片" : s.Record is not null ? $"语音 · {s.Record.DurationSec} 秒" : s.Video is not null ? "视频" : "表情");
                    body.Children.Add(MediaPreview(m, s, media, label));
                }
                else if (s.Forward is { } forward) body.Children.Add(ForwardCard(forward, inner, foreground, () => OnOriginalPage(() => ShowForward(m))));
                else if (s.LightApp is { } app) body.Children.Add(ChatPresentation.ParseAppCard(app.Json, app.AppName) is { } card
                    ? AppCardView(card, inner, foreground) : CardLine(ChatPresentation.CardText(app.Json), inner, foreground));
                else if (s.Xml is not null) body.Children.Add(CardLine("[卡片消息]", inner, foreground));
                else if (s.Unknown is { } unknown)
                {
                    // 骰子、猜拳只写一句；机器人按钮（keyboard）还没做，先不显示。
                    if (unknown.Original == "dice") Inline(new Run { Text = "[骰子]" });
                    else if (unknown.Original == "rps") Inline(new Run { Text = "[猜拳]" });
                    else if (unknown.Original != "keyboard") body.Children.Add(UnsupportedView(unknown, inner, foreground));
                }
            }
            if (m.Segments.Count == 0) foreach (var run in TextInlines(m.Text, own)) Inline(run);
            body.Children.Add(BubbleFooter(m, foreground));
            content = mediaOnly ? new Border { Child = body, HorizontalAlignment = own ? HorizontalAlignment.Right : HorizontalAlignment.Left } : new Border
            {
                Child = body, Padding = Res<object>("BubblePadding") is Thickness p ? p : new Thickness(12, 8, 12, 6),
                CornerRadius = Res<object>("OverlayCornerRadius") is CornerRadius r ? r : new CornerRadius(8),
                Background = own ? Brush("AccentFillColorDefaultBrush") : Brush("CardBackgroundFillColorDefaultBrush"),
                BorderBrush = own ? null : Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(own ? 0 : 1),
                MaxWidth = (double)Microsoft.UI.Xaml.Application.Current.Resources["BubbleMaxWidth"],
                HorizontalAlignment = own ? HorizontalAlignment.Right : HorizontalAlignment.Left
            };
        }
        content.Tag = m;
        if (includeActions)
        {
            // 不用 ContextFlyout：CommandBarFlyout 挂在列表项里的元素上不会打开，文字控件还会先弹自带的文字菜单（2026-10-17 实测）。
            // 自己处理 ContextRequested（右键、Shift+F10、菜单键都走这里），在点击位置打开。
            var menu = MessageMenu(m, own, group, pageToken, OnOriginalPage);
            void OpenMenu(UIElement sender, ContextRequestedEventArgs e)
            {
                e.Handled = true;
                var options = new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { ShowMode = Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowMode.Standard };
                if (e.TryGetPosition(content, out var point)) options.Position = point;
                menu.ShowAt(content, options);
            }
            content.ContextRequested += OpenMenu;
            foreach (var text in texts) { text.ContextFlyout = null; if (text is RichTextBlock r) r.SelectionFlyout = null; else if (text is TextBlock b) b.SelectionFlyout = null; }
        }

        var column = new StackPanel { Spacing = 2, HorizontalAlignment = own ? HorizontalAlignment.Right : HorizontalAlignment.Left };
        if (showSender) column.Children.Add(new TextBlock { Text = SenderDisplay(m), Style = Res<Style>("SecondaryCaptionTextBlockStyle"), Margin = new Thickness(2, 0, 0, 0) });
        column.Children.Add(content);
        if (m.Reactions.Count > 0) column.Children.Add(ReactionBar(m, own, group, pageToken));

        // 群里别人发的留出头像列；同一人连续发的只在第一条放头像，后面留空对齐。私聊和自己发的不显示头像。
        if (own || !group) return new Border { Child = column, Margin = new Thickness(0, showSender ? 6 : 2, 0, 2), HorizontalAlignment = own ? HorizontalAlignment.Right : HorizontalAlignment.Left };
        var row = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, showSender ? 6 : 2, 0, 2) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(32) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (showSender)
        {
            var avatar = new PersonPicture { Width = 32, Height = 32, DisplayName = SenderDisplay(m), VerticalAlignment = VerticalAlignment.Top, Tag = m.SenderId };
            avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, m.SenderId);
            row.Children.Add(avatar);
        }
        Grid.SetColumn(column, 1); row.Children.Add(column);
        return row;
    }

    private string SenderDisplay(ProtoMessage m) => m.SenderName.Length > 0 ? m.SenderName : PeerName(m.SenderId, Scene.Friend);

    // 只有 1–3 个 QQ 表情：放大显示、不要气泡（和 iOS / Telegram 一样）。
    private static FrameworkElement? JumboFaces(ProtoMessage m)
    {
        if (m.Segments.Count is < 1 or > 3 || m.Segments.Any(s => s.Face is null)) return null;
        double size = m.Segments.Count == 1 ? 72 : 52;
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var s in m.Segments)
        {
            if (FaceImage(s.Face.FaceId, size) is not { } image) return null;
            panel.Children.Add(image);
        }
        return panel;
    }

    // 文字里的链接用 Hyperlink（浏览器打开）；5 位以上数字点了复制（QQ 号、手机号）。
    private IEnumerable<Inline> TextInlines(string text, bool own)
    {
        foreach (var run in ChatPresentation.Linkify(text))
        {
            if (run.Kind == ChatPresentation.TextRunKind.Text) { yield return new Run { Text = run.Text }; continue; }
            var link = new Hyperlink();
            if (own) link.Foreground = Brush("TextOnAccentFillColorPrimaryBrush");
            link.Inlines.Add(new Run { Text = run.Text });
            if (run.Kind == ChatPresentation.TextRunKind.Link && Uri.TryCreate(run.Target, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
            {
                link.NavigateUri = uri;
                ToolTipService.SetToolTip(link, uri.AbsoluteUri);
            }
            else if (run.Kind == ChatPresentation.TextRunKind.Number)
            {
                string number = run.Target;
                link.Click += (_, _) =>
                {
                    var data = new DataPackage(); data.SetText(number); Clipboard.SetContent(data);
                    Notice.Severity = InfoBarSeverity.Informational; Notice.Message = "已复制 " + number; Notice.IsOpen = true;
                };
            }
            yield return link;
        }
    }

    // @ 徽章：小头像 + 名字，点开资料（iOS 的 mention 徽章）。手打的 @ 文字不会进这里。
    private FrameworkElement MentionChip(MentionSegment at, bool own, Func<Func<Task>, Task> onPage)
    {
        string name = at.Name.Length > 0 ? at.Name : PeerName(at.UserId, Scene.Friend);
        var avatar = new PersonPicture { Width = 16, Height = 16, DisplayName = name, Tag = at.UserId };
        avatar.Loaded += (_, _) => LoadSenderAvatar(avatar, at.UserId);
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        panel.Children.Add(avatar);
        panel.Children.Add(new TextBlock { Text = "@" + name, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Foreground = own ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("AccentTextFillColorPrimaryBrush") });
        var chip = new Button
        {
            Content = panel, Padding = new Thickness(2, 1, 8, 1), CornerRadius = new CornerRadius(10), MinHeight = 0, BorderThickness = new Thickness(0),
            Background = own ? OnAccentOverlay : Brush("SubtleFillColorSecondaryBrush"), Margin = new Thickness(0, 0, 2, -4)
        };
        ToolTipService.SetToolTip(chip, $"{name}（{at.UserId}）");
        chip.Click += async (_, _) => await Guard(() => onPage(async () =>
        {
            if (runtime is not { } session) return;
            var peer = peerIndex.GetValueOrDefault((at.UserId, false));
            if (peer is null)
            {
                var profile = await session.GetUserProfileAsync(new() { UserId = at.UserId }, pageTask?.Token ?? lifetime.Token);
                peer = profile.Profile?.Peer;
            }
            if (peer is not null && runtime == session) await Go(ProfileKey(peer), () => { NewPage(); ShowProfile(peer); });
        }));
        return chip;
    }

    // 引用块：左边一条竖线 + 原消息发送者和一行内容，点了跳到原消息。原消息不在当前窗口时也能点，跳过去再加载。
    private FrameworkElement ReplyQuote(ProtoMessage m, bool own, Brush inner, Func<Func<Task>, Task> onPage)
    {
        timelineMessages.TryGetValue(m.ReplyToSeq, out var target);
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock { Text = target is null ? "回复" : SenderDisplay(target), Style = Res<Style>("CaptionTextBlockStyle"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = own ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("AccentTextFillColorPrimaryBrush") });
        string preview = target is null ? "原消息不在当前加载范围，点击定位" : target.State == MessageState.Recalled ? "[已撤回] " + target.Text : target.Text.Length > 0 ? target.Text : "[消息]";
        text.Children.Add(new TextBlock { Text = preview.Replace('\n', ' '), Style = Res<Style>("CaptionTextBlockStyle"), MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.Wrap, Foreground = own ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("TextFillColorSecondaryBrush") });
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new Border { CornerRadius = new CornerRadius(1.5), Background = own ? Brush("TextOnAccentFillColorPrimaryBrush") : Brush("AccentFillColorDefaultBrush") });
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        var button = new Button { Content = grid, Padding = new Thickness(8, 6, 10, 6), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Background = inner, BorderThickness = new Thickness(0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "跳到被回复的消息");
        button.Click += async (_, _) => await Guard(() => onPage(() => Go(ChatKey(m.ChatId), () => OpenChat(m.ChatId, m.ReplyToSeq))));
        return button;
    }

    // 气泡右下角：撤回标记 + 时刻。
    private static FrameworkElement BubbleFooter(ProtoMessage m, Brush foreground)
    {
        var footer = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        if (m.State == MessageState.Recalled)
        {
            footer.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Foreground = foreground, Opacity = 0.7 });
            footer.Children.Add(new TextBlock { Text = "已撤回", Style = Res<Style>("BubbleTimeTextStyle"), Foreground = foreground });
        }
        footer.Children.Add(new TextBlock { Text = DateTimeOffset.FromUnixTimeSeconds(m.Time).ToLocalTime().ToString("HH:mm"), Style = Res<Style>("BubbleTimeTextStyle"), Foreground = foreground });
        return footer;
    }

    private static Border InnerCard(UIElement child, Brush inner) => new() { Child = child, Background = inner, CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 8, 10, 8) };

    // 合并转发：标题、前几条预览、底部「聊天记录」，点开阅读器。
    private static FrameworkElement ForwardCard(ForwardSegment forward, Brush inner, Brush foreground, Func<Task> open)
    {
        var panel = new StackPanel { Spacing = 3, MinWidth = 220 };
        panel.Children.Add(new TextBlock { Text = forward.Title.Length > 0 ? forward.Title : "聊天记录", Style = Res<Style>("BodyStrongTextBlockStyle"), Foreground = foreground, TextTrimming = TextTrimming.CharacterEllipsis });
        foreach (var line in forward.Preview.Take(4))
            panel.Children.Add(new TextBlock { Text = line, Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground, Opacity = 0.8, TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(new Border { Height = 1, Background = foreground, Opacity = 0.2, Margin = new Thickness(0, 4, 0, 2) });
        panel.Children.Add(new TextBlock { Text = forward.Summary.Length > 0 ? forward.Summary : "聊天记录", Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground, Opacity = 0.8 });
        var button = new Button { Content = panel, Padding = new Thickness(10, 8, 10, 8), Background = inner, BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        button.Click += async (_, _) => await open();
        return button;
    }

    // 小程序 / 分享卡片：来源、标题、简介、封面；有能用浏览器打开的链接才可点。
    private static FrameworkElement AppCardView(ChatPresentation.AppCard card, Brush inner, Brush foreground)
    {
        var panel = new StackPanel { Spacing = 4, Width = 280 };
        panel.Children.Add(new TextBlock { Text = card.Source, Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground, Opacity = 0.75, TextTrimming = TextTrimming.CharacterEllipsis });
        if (card.Title.Length > 0) panel.Children.Add(new TextBlock { Text = card.Title, Style = Res<Style>("BodyStrongTextBlockStyle"), Foreground = foreground, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis });
        if (card.Description.Length > 0) panel.Children.Add(new TextBlock { Text = card.Description, Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground, Opacity = 0.8, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis });
        if (card.Preview.Length > 0 && Uri.TryCreate(card.Preview, UriKind.Absolute, out var preview))
            panel.Children.Add(new Border { CornerRadius = new CornerRadius(4), Margin = new Thickness(0, 4, 0, 0), Child = new Image { Source = new BitmapImage(preview) { DecodePixelWidth = 560 }, MaxHeight = 160, Stretch = Stretch.UniformToFill } });
        if (card.Url.Length == 0 || !Uri.TryCreate(card.Url, UriKind.Absolute, out var url)) return InnerCard(panel, inner);
        var button = new Button { Content = panel, Padding = new Thickness(10, 8, 10, 8), Background = inner, BorderThickness = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Left };
        ToolTipService.SetToolTip(button, url.AbsoluteUri);
        button.Click += async (_, _) => await Launcher.LaunchUriAsync(url);
        return button;
    }

    private static FrameworkElement CardLine(string text, Brush inner, Brush foreground) => InnerCard(new TextBlock { Text = text, Foreground = foreground, TextWrapping = TextWrapping.Wrap }, inner);

    // 还不支持的元素：图标 + 是什么 + 一句说明（红包标题、长消息提示……），点开看原始数据（iOS UnsupportedItem）。
    private FrameworkElement UnsupportedView(UnknownSegment unknown, Brush inner, Brush foreground)
    {
        var info = ChatPresentation.Unsupported(unknown.Original, unknown.DataJson);
        var grid = new Grid { ColumnSpacing = 10, MinWidth = 220 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = info.Glyph, FontSize = 20, Foreground = foreground, VerticalAlignment = VerticalAlignment.Center });
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock { Text = info.Title, Style = Res<Style>("BodyStrongTextBlockStyle"), Foreground = foreground });
        text.Children.Add(new TextBlock { Text = info.Subtitle, Style = Res<Style>("CaptionTextBlockStyle"), Foreground = foreground, Opacity = 0.8, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        var button = new Button { Content = grid, Padding = new Thickness(10, 8, 10, 8), Background = inner, BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
        ToolTipService.SetToolTip(button, "查看原始数据");
        button.Click += async (_, _) => await Guard(() => DialogBox(info.Title + " · 原始数据", new ScrollViewer
        {
            MaxHeight = 480, Content = new TextBlock { Text = PrettyJson(unknown.DataJson), FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap }
        }));
        return button;
    }

    private static string PrettyJson(string json)
    {
        try { using var doc = System.Text.Json.JsonDocument.Parse(json); return System.Text.Json.JsonSerializer.Serialize(doc.RootElement, new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }); }
        catch (System.Text.Json.JsonException) { return json; }
    }

    // 回应条：气泡下面一排「表情 数量」，自己点过的高亮；群里可以点来加 / 取消，右键看谁点了。
    private FrameworkElement ReactionBar(ProtoMessage m, bool own, bool group, CancellationToken pageToken)
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = own ? HorizontalAlignment.Right : HorizontalAlignment.Left, Margin = new Thickness(0, 2, 0, 0) };
        foreach (var reaction in m.Reactions)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            if (FaceImage(reaction.EmojiId, 16) is { } face) content.Children.Add(face);
            else content.Children.Add(new TextBlock { Text = ReactionEmoji(reaction.EmojiId), FontSize = 13 });
            content.Children.Add(new TextBlock { Text = reaction.Count.ToString(System.Globalization.CultureInfo.InvariantCulture), Style = Res<Style>("CaptionTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center });
            var toggle = new ToggleButton { Content = content, IsChecked = reaction.Me, Padding = new Thickness(6, 2, 8, 2), MinHeight = 0, CornerRadius = new CornerRadius(12), IsEnabled = group && m.State == MessageState.Normal };
            ToolTipService.SetToolTip(toggle, reaction.Me ? "取消回应（右键查看谁回应了）" : "回应（右键查看谁回应了）");
            string emoji = reaction.EmojiId; bool mine = reaction.Me;
            // 读屏要能念出是哪个回应、几个人、我有没有点过（原来按钮没有名字，只念「切换按钮」，2026-10-19 实测）。
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, $"回应 {(faces.TryGetValue(emoji, out var faceEntry) ? faceEntry.Name : ReactionEmoji(emoji))}，{reaction.Count} 人" + (mine ? "，包括我" : ""));
            toggle.Click += async (_, _) => await Guard(() => React(m, emoji, !mine, pageToken));
            toggle.RightTapped += async (_, e) => { e.Handled = true; await Guard(() => ShowReactionUsers(m, emoji)); };
            bar.Children.Add(toggle);
        }
        return bar;
    }

    // QQ 的回应 id：小号是 QQ 表情，大号是 Unicode 码位（128077 = 👍）。
    private static string ReactionEmoji(string id) =>
        int.TryParse(id, out int code) && code > 0x2000 && code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF) ? char.ConvertFromUtf32(code) : "[" + id + "]";

    private async Task React(ProtoMessage m, string emoji, bool add, CancellationToken ct)
    {
        if (runtime is not { } session) return;
        await using var vm = new MessageActionsViewModel(m.ChatId, m.Seq, session.RecallMessageAsync, session.ReactAsync, new UiDispatcher(DispatcherQueue));
        if (await vm.ReactAsync(emoji, add, ct) || runtime != session || ct.IsCancellationRequested) return;
        throw new IOException((vm.React.Error ?? "回应未完成。") + (vm.React.OutcomeUncertain ? " 请等待同步确认，避免重复操作。" : ""));
    }

    // 消息右键菜单：CommandBarFlyout，上面一排常用（回复、复制、转发、群里的 👍），展开后是其余操作。
    private CommandBarFlyout MessageMenu(ProtoMessage m, bool own, bool group, CancellationToken pageToken, Func<Func<Task>, Task> onPage)
    {
        var menu = new CommandBarFlyout { AlwaysExpanded = true };
        AppBarButton Command(string label, string glyph, Func<Task> action)
        {
            var button = new AppBarButton { Label = label, Icon = new FontIcon { Glyph = glyph } };
            ToolTipService.SetToolTip(button, label);
            button.Click += async (_, _) => { menu.Hide(); await Guard(() => onPage(action)); };
            return button;
        }
        void Primary(string label, string glyph, Func<Task> action) => menu.PrimaryCommands.Add(Command(label, glyph, action));
        void Secondary(string label, string glyph, Func<Task> action) => menu.SecondaryCommands.Add(Command(label, glyph, action));
        bool normal = m.State == MessageState.Normal;
        Primary("回复", "\uE97A", () =>
        {
            if (selectedChat != m.ChatId) return Task.CompletedTask;
            replySeq = m.Seq; replies[m.ChatId] = replySeq; dirtyDrafts.Add(m.ChatId); draftTimer.Start(); UpdateReply(); Composer.Focus(FocusState.Keyboard); return Task.CompletedTask;
        });
        Primary("复制", "\uE8C8", () => { var data = new DataPackage(); data.SetText(m.Text); Clipboard.SetContent(data); return Task.CompletedTask; });
        if (runtime is { } forwardingSession && normal) Primary("转发", "\uE72D", () => Forward(forwardingSession, m.ChatId, [m.Seq]));
        if (normal && group) Primary("👍", "\uE8E1", () => React(m, "128077", !m.Reactions.Any(r => r.EmojiId == "128077" && r.Me), pageToken));
        if (normal && selectedChat == m.ChatId) Secondary("选择", "\uE762", () => { EnterSelection(m.Seq); return Task.CompletedTask; });
        if (runtime is { } stickerSession)
        {
            int index = 0;
            foreach (var segment in m.Segments.Where(s => s.Image is not null || s.MarketFace is not null))
            {
                var sha = Media(segment)?.Sha256;
                if (sha is { Length: 64 }) Secondary(index++ == 0 ? "收藏为表情" : $"收藏第 {index} 张为表情", "\uE734", () => AddMessageSticker(sha, stickerSession));
            }
        }
        if (runtime is { } voiceSession && m.Segments.Any(s => s.Record is not null))
        {
            Secondary("语音转文字", "\uE8D2", async () =>
            {
                if (runtime != voiceSession) return;
                await using var operation = new RpcOperationViewModel<TranscribeVoiceRequest, TranscribeVoiceResponse>(voiceSession.TranscribeVoiceAsync, new UiDispatcher(DispatcherQueue), false);
                bool succeeded = await operation.ExecuteAsync(new() { ChatId = m.ChatId, Seq = m.Seq }, pageToken);
                pageToken.ThrowIfCancellationRequested();
                if (runtime != voiceSession) return;
                if (!succeeded) throw new IOException(operation.Error ?? "语音识别失败。");
                string text = operation.Result!.Text;
                await DialogBox("语音转文字", Text(text.Length > 0 ? text : "未识别出文字"));
            });
        }
        foreach (var reaction in m.Reactions)
        {
            string emoji = reaction.EmojiId;
            Secondary($"谁回应了 {ReactionEmoji(emoji)}", "\uE716", () => ShowReactionUsers(m, emoji));
        }
        if (own && normal && runtime is { } actionSession)
        {
            if (menu.SecondaryCommands.Count > 0) menu.SecondaryCommands.Add(new AppBarSeparator());
            Secondary("撤回", "\uE7A7", async () =>
            {
                if (runtime != actionSession) return;
                await using var vm = new MessageActionsViewModel(m.ChatId, m.Seq, actionSession.RecallMessageAsync, actionSession.ReactAsync, new UiDispatcher(DispatcherQueue));
                if (await vm.RecallAsync(pageToken) || runtime != actionSession || pageToken.IsCancellationRequested) return;
                throw new IOException((vm.Recall.Error ?? "撤回未完成。") + (vm.Recall.OutcomeUncertain ? " 请等待同步确认，避免重复操作。" : ""));
            });
        }
        return menu;
    }
    // 气泡和 @ 徽章里的用户头像，与列表头像共用缓存、批量查询和下载并发限制。
    private async void LoadSenderAvatar(PersonPicture picture, long userId, bool group = false)
    {
        if (api is null || userId == 0) return;
        var sessionApi = api;
        string hash = peerIndex.GetValueOrDefault((userId, group))?.AvatarSha256 ?? "";
        try
        {
            var bitmap = await AvatarImage(sessionApi, userId, group, hash);
            if (api == sessionApi && picture.Tag is long id && id == userId && bitmap is not null) picture.ProfilePicture = bitmap;
        }
        catch (OperationCanceledException) { }
        catch (Exception) { /* 失败保留姓名占位，缓存已移除，下次显示时重试。 */ }
    }
}
