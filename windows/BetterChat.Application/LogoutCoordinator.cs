namespace BetterChat.Application;

public sealed record LogoutResult(bool RemoteRevoked);

public static class LogoutCoordinator
{
    public static async Task<LogoutResult> RunAsync(Func<Task> persistDrafts, Action clearCredentials,
        Func<CancellationToken, Task> revoke, Func<Task> close, TimeSpan? timeout = null)
    {
        // 本地保存失败时仍保留登录状态；凭据清除失败时也不能声称已经退出。
        await persistDrafts();
        clearCredentials();
        bool revoked = false;
        using var deadline = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(5));
        try
        {
            var revocation = revoke(deadline.Token);
            _ = revocation.ContinueWith(task => _ = task.Exception, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            await revocation.WaitAsync(deadline.Token); revoked = true;
        }
        catch (BetterChat.Core.RpcException error) when (error.Code == "unauthenticated") { revoked = true; }
        catch (Exception) { /* 远端不可达不能阻止本机退出；由结果提示远端凭据可能仍有效。 */ }
        await close();
        return new(revoked);
    }
}
