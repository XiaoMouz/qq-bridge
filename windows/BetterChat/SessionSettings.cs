using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BetterChat.Application;

namespace BetterChat;
public sealed record SessionSettings(string Server, string ProtectedToken)
{
    public static string Root { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BetterChat");
    private static string FilePath => Path.Combine(Root, "session.json");
    public static string? LoadError { get; private set; }
    private string? validatedToken;
    private static string Decrypt(string value) => Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser));
    public static SessionSettings? Load()
    {
        LoadError = null;
        try
        {
            if (!File.Exists(FilePath)) return null;
            if (new FileInfo(FilePath).Length > 65536) throw new InvalidDataException();
            var saved = SavedSessionReader.Read(File.ReadAllText(FilePath), Decrypt);
            return new(saved.Server, saved.ProtectedToken) { validatedToken = saved.Token };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or CryptographicException or FormatException)
        {
            // 不删除损坏文件，也不把凭据或底层解密细节写入界面；用户重新登录会原子替换它。
            LoadError = "无法读取保存的登录信息，请重新登录。";
            return null;
        }
    }
    [System.Text.Json.Serialization.JsonIgnore]
    public string Token => validatedToken ?? Decrypt(ProtectedToken);
    public static void Save(string server, string token)
    {
        Directory.CreateDirectory(Root);
        var settings = new SessionSettings(server, Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(token), null, DataProtectionScope.CurrentUser)));
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(new { settings.Server, settings.ProtectedToken }));
        File.Move(FilePath + ".tmp", FilePath, true);
    }
    public static bool RemoveLegacyPlaintext()
    {
        var saved = Load(); if (saved is null) return false;
        using var document = JsonDocument.Parse(File.ReadAllText(FilePath));
        if (!document.RootElement.TryGetProperty("Token", out _)) return false;
        Save(saved.Server, saved.Token);
        return true;
    }
    public static void Clear()
    {
        // 保存中断可能留下同样含凭据的临时文件，退出时一并清除。
        if (File.Exists(FilePath + ".tmp")) File.Delete(FilePath + ".tmp");
        if (File.Exists(FilePath)) File.Delete(FilePath);
    }
    // 退出时选择清除本机缓存：数据库（含 WAL / SHM）和媒体预览目录。调用前账号必须已经断开；
    // Microsoft.Data.Sqlite 的连接池会继续占着文件，先清空连接池再删。
    public static void DeleteCache(string path)
    {
        if (!path.StartsWith(Root, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("只能删除 BetterChat 自己的缓存。", nameof(path));
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        foreach (var file in new[] { path, path + "-wal", path + "-shm" }) if (File.Exists(file)) File.Delete(file);
        if (Directory.Exists(path + ".media")) Directory.Delete(path + ".media", true);
    }
    public static string CachePath(string server, string token)
    {
        // 服务器与设备凭据分区，避免切换账号时显示上一个账号的缓存。
        string key = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(server + "\n" + token)))[..24];
        Directory.CreateDirectory(Root); return Path.Combine(Root, key + ".db");
    }
}
