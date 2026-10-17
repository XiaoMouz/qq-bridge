using System.Security.Cryptography;

namespace BetterChat.Application;

public static class MessageIdentity
{
    // 后端使用 Number.isSafeInteger 校验；proto int64 不代表服务端接受全部 64 位范围。
    public const long MaxValue = (1L << 53) - 1;
    public static long Create()
    {
        long value;
        do { value = BitConverter.ToInt64(RandomNumberGenerator.GetBytes(8)) & MaxValue; } while (value == 0);
        return value;
    }
}
