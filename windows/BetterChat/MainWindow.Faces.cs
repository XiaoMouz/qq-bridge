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
    private static Image? FaceImage(string id)
    {
        if (!faces.TryGetValue(id, out var entry)) return null;
        var image = new Image { Source = new BitmapImage(new Uri(entry.ImagePath)) { DecodePixelWidth = 64 }, Width = 24, Height = 24, Stretch = Stretch.Uniform };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(image, entry.Name);
        ToolTipService.SetToolTip(image, entry.Name);
        return image;
    }
    private void ChooseFace(object sender, RoutedEventArgs args)
    {
        if (selectedChat == 0) return;
        long chat = selectedChat; int start = Composer.SelectionStart, length = Composer.SelectionLength;
        var search = new TextBox { PlaceholderText = "搜索 QQ 表情" };
        var grid = new GridView
        {
            Height = 300, Width = 352, IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.None,
            ItemTemplate = (DataTemplate)Root.Resources["FaceTemplate"],
            ItemsSource = faces.Values.Where(f => !f.Hidden).ToList()
        };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(search); panel.Children.Add(grid);
        var popup = new Flyout { Content = panel, Placement = FlyoutPlacementMode.TopEdgeAlignedLeft };
        search.TextChanged += (_, _) => grid.ItemsSource = faces.Values.Where(f => !f.Hidden && (f.Name.Contains(search.Text.Trim(), StringComparison.OrdinalIgnoreCase) || f.Id == search.Text.Trim())).ToList();
        grid.ItemClick += (_, e) =>
        {
            if (chat != selectedChat || e.ClickedItem is not FaceEntry face) { popup.Hide(); return; }
            var document = CurrentDocument();
            int caret = document.Insert(start, length, "[" + face.Name + "]", new OutgoingSegment { FaceId = face.Id });
            Composer.Text = document.Text; Composer.SelectionStart = caret; Composer.SelectionLength = 0;
            popup.Hide(); Composer.Focus(FocusState.Keyboard);
        };
        popup.ShowAt(FaceButton);
    }
}
