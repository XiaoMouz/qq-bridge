using System.Text.Json;
using Microsoft.UI.Xaml;

namespace BetterChat;

internal sealed record AppearanceSettings(ElementTheme Theme = ElementTheme.Default)
{
    private static string FilePath => Path.Combine(SessionSettings.Root, "appearance.json");
    public static AppearanceSettings Load()
    {
        try
        {
            var saved = File.Exists(FilePath) ? JsonSerializer.Deserialize<AppearanceSettings>(File.ReadAllText(FilePath)) : null;
            return saved is not null && Enum.IsDefined(saved.Theme) ? saved : new();
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
