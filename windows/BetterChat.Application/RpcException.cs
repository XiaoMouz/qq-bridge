namespace BetterChat.Core;

public sealed class RpcException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

