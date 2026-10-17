using System.Text.Json;
using Microsoft.UI.Xaml;

namespace BetterChat;

// ListPaneWidth：中栏列表拖动后的宽度（宽窗口下生效，260–420）。
internal sealed record AppearanceSettings(ElementTheme Theme = ElementTheme.Default, double ListPaneWidth = AppearanceSettings.DefaultListPaneWidth)
{
    public const double DefaultListPaneWidth = 320, MinListPaneWidth = 260, MaxListPaneWidth = 420;
    private static string FilePath => Path.Combine(SessionSettings.Root, "appearance.json");
    public static AppearanceSettings Load()
    {
        try
        {
            var saved = File.Exists(FilePath) ? JsonSerializer.Deserialize<AppearanceSettings>(File.ReadAllText(FilePath)) : null;
            if (saved is null || !Enum.IsDefined(saved.Theme)) return new();
            return double.IsFinite(saved.ListPaneWidth) ? saved with { ListPaneWidth = Math.Clamp(saved.ListPaneWidth, MinListPaneWidth, MaxListPaneWidth) } : saved with { ListPaneWidth = DefaultListPaneWidth };
        }
        catch (JsonException) { return new(); }
        catch (IOException) { return new(); }
        catch (UnauthorizedAccessException) { return new(); }
    }
    public void Save()
    {
        Directory.CreateDirectory(SessionSettings.Root);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
}
