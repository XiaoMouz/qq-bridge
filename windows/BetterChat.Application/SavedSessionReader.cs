using System.Text.Json;
using BetterChat.Core;

namespace BetterChat.Application;

public sealed record ValidatedSession(string Server, string ProtectedToken, string Token);

public static class SavedSessionReader
{
    private sealed record Envelope(string? Server, string? ProtectedToken);
    public static ValidatedSession Read(string json, Func<string, string> decrypt)
    {
        if (json.Length > 65536) throw new InvalidDataException("保存的登录信息过大。");
        var envelope = JsonSerializer.Deserialize<Envelope>(json);
        if (envelope is null || string.IsNullOrWhiteSpace(envelope.Server) || string.IsNullOrWhiteSpace(envelope.ProtectedToken))
            throw new InvalidDataException("保存的登录信息不完整。");
        Authentication.ServerUri(envelope.Server);
        string token = decrypt(envelope.ProtectedToken);
        if (string.IsNullOrWhiteSpace(token)) throw new InvalidDataException("保存的凭据为空。");
        return new(envelope.Server, envelope.ProtectedToken, token);
    }
}
