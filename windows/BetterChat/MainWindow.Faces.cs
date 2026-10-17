using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Qqbridge.V1;

namespace BetterChat;

public sealed record FaceEntry(string Id, string Name, int Type, bool Hidden)
{
    public string ImagePath => $"ms-appx:///Assets/QQFaces/s{Id}.png";
    public override string ToString() => Name;
}

public sealed partial class MainWindow
{
    private static readonly IReadOnlyDictionary<string, FaceEntry> faces = LoadFaces();
    private static IReadOnlyDictionary<string, FaceEntry> LoadFaces()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "Assets", "FaceCatalog.json");
        return (JsonSerializer.Deserialize<List<FaceEntry>>(File.ReadAllText(path)) ?? []).ToDictionary(f => f.Id);
    }
    private static Image? FaceImage(string id, double size = 24)
    {
        if (!faces.TryGetValue(id, out var entry)) return null;
        var image = new Image { Source = new BitmapImage(new Uri(entry.ImagePath)) { DecodePixelWidth = (int)Math.Max(64, size * 2) }, Width = size, Height = size, Stretch = Stretch.Uniform };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(image, entry.Name);
        ToolTipService.SetToolTip(image, entry.Name);
        return image;
    }
    // 表情面板：SelectorBar 切换「QQ 表情」和「收藏」；QQ 表情插入输入框，收藏表情点了直接发送（同 iOS）。
    private void ChooseFace(object sender, RoutedEventArgs args)
    {
        if (selectedChat == 0) return;
        long chat = selectedChat; int start = Composer.SelectionStart, length = Composer.SelectionLength;
        var popup = new Flyout { Placement = FlyoutPlacementMode.TopEdgeAlignedLeft };
        var tabs = new SelectorBar();
        var faceTab = new SelectorBarItem { Text = "QQ 表情", IsSelected = true };
        var stickerTab = new SelectorBarItem { Text = "收藏" };
        tabs.Items.Add(faceTab); tabs.Items.Add(stickerTab);
        var search = new AutoSuggestBox { PlaceholderText = "按名称或编号搜索", QueryIcon = new SymbolIcon(Symbol.Find) };
        var grid = new GridView
        {
            Height = 300, Width = 360, IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.None,
            ItemTemplate = (DataTemplate)Root.Resources["FaceTemplate"],
            ItemsSource = faces.Values.Where(f => !f.Hidden).ToList()
        };
        var facePage = new StackPanel { Spacing = 8 }; facePage.Children.Add(search); facePage.Children.Add(grid);
        var host = new ContentControl { Content = facePage, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        FrameworkElement? stickerPage = null;
        var panel = new StackPanel { Spacing = 8, Width = 376 }; panel.Children.Add(tabs); panel.Children.Add(host);
        popup.Content = panel;
        tabs.SelectionChanged += (_, _) =>
        {
            if (tabs.SelectedItem == stickerTab) host.Content = stickerPage ??= StickerPanel(popup, chat);
            else host.Content = facePage;
        };
        search.TextChanged += (_, _) => grid.ItemsSource = faces.Values.Where(f => !f.Hidden && (f.Name.Contains(search.Text.Trim(), StringComparison.OrdinalIgnoreCase) || f.Id == search.Text.Trim())).ToList();
        grid.ItemClick += (_, e) =>
        {
            if (chat != selectedChat || e.ClickedItem is not FaceEntry face) { popup.Hide(); return; }
            var document = CurrentDocument();
            int caret = document.Insert(start, length, "[" + face.Name + "]", new OutgoingSegment { FaceId = face.Id });
            Composer.Text = document.Text; Composer.SelectionStart = caret; Composer.SelectionLength = 0;
            start = caret; length = 0;
            // 按住 Shift 点可以连续插入多个，不关闭面板。
            if (!Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
            { popup.Hide(); Composer.Focus(FocusState.Keyboard); }
        };
        popup.ShowAt(FaceButton);
    }
}
