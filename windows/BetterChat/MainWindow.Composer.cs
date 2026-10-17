using BetterChat.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private void ComposerBeforeTextChanging(TextBox sender, TextBoxBeforeTextChangingEventArgs args)
    {
        if (rendering || selectedChat == 0) return;
        if (!drafts.TryGetValue(selectedChat, out var document)) drafts[selectedChat] = document = new ComposerDocument();
        document.UpdateText(args.NewText, sender.SelectionStart, sender.SelectionLength);
    }
    private string OutgoingPreview(IEnumerable<OutgoingSegment> segments) => ComposerDocument.FromSegments(segments, id => PeerName(id, Scene.Friend)).Text;
    private ComposerDocument CurrentDocument()
    {
        if (!drafts.TryGetValue(selectedChat, out var document)) drafts[selectedChat] = document = new ComposerDocument();
        document.UpdateText(Composer.Text);
        return document;
    }
    private async void ChooseMention(object sender, RoutedEventArgs args) => await Guard(async () =>
    {
        if (api is not { } sessionApi || dialogIndex.GetValueOrDefault(selectedChat) is not { Scene: Scene.Group } chat) return;
        long chatId = selectedChat;
        int insertion = Composer.SelectionStart, selection = Composer.SelectionLength;
        using var source = CancellationTokenSource.CreateLinkedTokenSource(pageTask?.Token ?? lifetime.Token);
        var ct = source.Token;
        var search = new TextBox { PlaceholderText = "按群名片、昵称或 QQ 号筛选已加载成员" };
        var list = new ListView { Height = 320, SelectionMode = ListViewSelectionMode.Single, DisplayMemberPath = "Title" };
        var status = Text("正在加载群成员…", 12);
        var more = new Button { Content = "加载更多成员" };
        var panel = new StackPanel { Spacing = 12, Width = 420 };
        panel.Children.Add(search); panel.Children.Add(status); panel.Children.Add(list); panel.Children.Add(more);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "提及群成员", Content = panel, PrimaryButtonText = "插入", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        var rows = new List<ListEntry>(); var seen = new HashSet<long>(); int offset = 0; bool busy = false;
        if (peerIndex.GetValueOrDefault((chat.PeerId, true))?.SelfRole is "owner" or "admin") rows.Add(new("全体成员", "", "", new OutgoingSegment { MentionAll = true }));
        void Filter()
        {
            var query = search.Text.Trim();
            list.ItemsSource = rows.Where(r => query.Length == 0 || r.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || r.Subtitle.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
        }
        async Task Load()
        {
            if (busy) return; busy = true; more.IsEnabled = false;
            try
            {
                var page = await SessionFor(sessionApi).ListGroupMembersAsync(new() { GroupId = chat.PeerId, Offset = offset, Limit = 100 }, ct);
                ct.ThrowIfCancellationRequested();
                foreach (var member in page.Members)
                {
                    if (!seen.Add(member.UserId)) continue;
                    string name = member.Card.Length > 0 ? member.Card : member.Nickname.Length > 0 ? member.Nickname : member.UserId.ToString();
                    rows.Add(new(name, member.UserId + " " + member.Nickname, "", new OutgoingSegment { MentionUserId = member.UserId }));
                }
                offset += page.Members.Count; Filter();
                status.Text = $"已加载 {seen.Count} / {page.Total} 位成员";
                more.Visibility = page.Members.Count > 0 && offset < page.Total ? Visibility.Visible : Visibility.Collapsed;
            }
            catch (OperationCanceledException) { }
            catch (Exception) { status.Text = "成员加载失败，请重试。"; more.Content = "重试加载"; }
            finally { busy = false; more.IsEnabled = true; }
        }
        search.TextChanged += (_, _) => Filter();
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedItem is ListEntry;
        more.Click += async (_, _) => await Load();
        dialog.Opened += async (_, _) => await Load();
        dialog.Closed += (_, _) => source.Cancel();
        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary || selectedChat != chatId || api != sessionApi || list.SelectedItem is not ListEntry chosen) return;
        var document = CurrentDocument();
        int caret = document.Insert(insertion, selection, "@" + chosen.Title, (OutgoingSegment)chosen.Value);
        Composer.Text = document.Text; Composer.SelectionStart = caret; Composer.SelectionLength = 0;
        Composer.Focus(FocusState.Keyboard);
    });
}
