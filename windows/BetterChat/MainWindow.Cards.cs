using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace BetterChat;

// 设置、资料页的积木：SettingsCard（标题 + 说明 + 图标 + 右侧内容 / 可点）、分组标题、页头（大头像或图标 + 名称 + 副标题）。
public sealed partial class MainWindow
{
    private SettingsCard Card(string header, string? description, string glyph, object? content = null, Func<Task>? click = null)
    {
        var card = click is null ? new SettingsCard() : new ClickableSettingsCard { IsClickEnabled = true };
        card.Header = header; card.HeaderIcon = new FontIcon { Glyph = glyph }; card.Content = content;
        if (description is not null) card.Description = description;
        if (click is not null)
        {
            async void Run() { card.IsEnabled = false; try { await Guard(click); } finally { card.IsEnabled = true; } }
            card.Click += (_, _) => Run();
            ((ClickableSettingsCard)card).Invoked = Run;
        }
        return card;
    }

    private static TextBlock SectionHeader(string text) => new()
    {
        Text = text, Style = Res<Style>("BodyStrongTextBlockStyle"), Margin = new Thickness(1, 12, 0, 0)
    };

    // 小号的说明文字，放在卡片右侧（数量、大小、时间）。
    private static TextBlock CardValue(string text) => new() { Text = text, Style = Res<Style>("SecondaryCaptionTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center };

    private static FrameworkElement Hero(UIElement picture, string title, params string[] lines)
    {
        var grid = new Grid { ColumnSpacing = 20, Margin = new Thickness(0, 0, 0, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(picture);
        var text = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, Style = Res<Style>("TitleTextBlockStyle"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        foreach (var line in lines.Where(l => l.Length > 0))
            text.Children.Add(new TextBlock { Text = line, Style = Res<Style>("BodyTextBlockStyle"), Foreground = Brush("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        return grid;
    }

    private static FrameworkElement GlyphTile(string glyph, double size = 72) => new Border
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 4), Background = Brush("AccentFillColorDefaultBrush"),
        Child = new FontIcon { Glyph = glyph, FontSize = size * 0.45, Foreground = Brush("TextOnAccentFillColorPrimaryBrush") }
    };

    // 一排操作按钮（第一个用强调色）。
    private StackPanel ActionRow(params (string Label, string Glyph, Func<Task> Action)[] actions)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 4) };
        bool first = true;
        foreach (var (label, glyph, action) in actions)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14 });
            content.Children.Add(new TextBlock { Text = label });
            var button = new Button { Content = content };
            if (first) button.Style = Res<Style>("AccentButtonStyle");
            first = false;
            button.Click += async (_, _) => { button.IsEnabled = false; try { await Guard(action); } finally { button.IsEnabled = true; } };
            row.Children.Add(button);
        }
        return row;
    }
}
