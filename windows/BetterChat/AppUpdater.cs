using System.Reflection;
using System.Text.Json;
using BetterChat.Application;
using Microsoft.UI.Dispatching;
using Velopack;

namespace BetterChat;

// Velopack 自动更新：后台检查、后台下载，下好后「设置」上亮一个圆点；关于页可以立即「重启并更新」，不点的话退出时安静地换上。
// 更新源是发布流水线编进程序集的 UpdateUrl（R2：…/betterchat/windows/x64）；本机构建没有它，或不是用 Setup 安装的，就不检查。
// 安装目录是 %LocalAppData%\XiaoMouz.BetterChat（包 ID），和数据目录 %LocalAppData%\BetterChat 分开：卸载会删安装目录整个文件夹。
internal sealed class AppUpdater
{
    // 检查失败后至少隔这么久再试，免得断网时每次切回窗口都去查。
    private static readonly TimeSpan RetryAfterFailure = TimeSpan.FromMinutes(30);
    private static string FilePath => Path.Combine(SessionSettings.Root, "update.json");

    private readonly UpdateManager? manager;
    private readonly DispatcherQueue dispatcher;
    private VelopackAsset? ready;
    private DateTimeOffset? lastCheck, lastAttempt;
    private string? seenVersion;

    public AppUpdateState State { get; private set; } = new(UpdatePhase.Unavailable);
    public event Action? Changed;

    // debugSource：启动参数 -debugUpdateSource <地址或本地目录>，验收时指向本机打的包，不碰线上 R2。
    public AppUpdater(DispatcherQueue dispatcher, string? debugSource)
    {
        this.dispatcher = dispatcher;
        Load();
        string? source = debugSource ?? typeof(AppUpdater).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "UpdateUrl")?.Value;
        if (string.IsNullOrWhiteSpace(source)) return;
        try
        {
            var candidate = new UpdateManager(source);
            if (!candidate.IsInstalled) return;
            manager = candidate;
        }
        catch (Exception) { return; }
        // 上次下好但还没换上的（比如上次退出前没来得及）：直接显示为可更新。
        if (manager.UpdatePendingRestart is { } pending)
        {
            ready = pending;
            State = new(UpdatePhase.Ready, pending.Version.ToString(), 100, lastCheck, pending.NotesMarkdown);
        }
        else State = new(UpdatePhase.Idle, LastCheck: lastCheck);
    }

    public string CurrentVersion => manager?.CurrentVersion?.ToString() ?? typeof(AppUpdater).Assembly.GetName().Version?.ToString(3) ?? "";
    public bool ShowsBadge => State.ShowsBadge(seenVersion);

    // 进过一次「关于」：这个版本的圆点不再亮。
    public void MarkSeen()
    {
        if (State.Phase != UpdatePhase.Ready || State.Version == seenVersion) return;
        seenVersion = State.Version; Save(); Changed?.Invoke();
    }

    public Task CheckIfDueAsync()
    {
        var now = DateTimeOffset.Now;
        if (!AppUpdateState.IsDue(lastCheck, now) || lastAttempt is { } attempt && now - attempt < RetryAfterFailure) return Task.CompletedTask;
        return CheckAsync();
    }

    public async Task CheckAsync()
    {
        if (manager is null || !State.CanCheck) return;
        lastAttempt = DateTimeOffset.Now;
        Set(State with { Phase = UpdatePhase.Checking });
        try
        {
            var info = await manager.CheckForUpdatesAsync();
            lastCheck = DateTimeOffset.Now; Save();
            if (info is null) { Set(new(UpdatePhase.Idle, LastCheck: lastCheck)); return; }
            var target = info.TargetFullRelease;
            string version = target.Version.ToString();
            Set(new(UpdatePhase.Downloading, version, 0, lastCheck));
            // 进度回调在下载线程上，回 UI 线程再改状态。
            await manager.DownloadUpdatesAsync(info, progress => dispatcher.TryEnqueue(() =>
            {
                if (State.Phase == UpdatePhase.Downloading) Set(State with { Progress = progress });
            }));
            ready = target;
            Set(new(UpdatePhase.Ready, version, 100, lastCheck, target.NotesMarkdown));
        }
        catch (Exception) { Set(new(UpdatePhase.Failed, LastCheck: lastCheck)); }
    }

    // 「重启并更新」：Velopack 的 Update.exe 等本进程退出、换文件、再启动新版本。
    public void RestartNow() { if (manager is not null && ready is not null) manager.ApplyUpdatesAndRestart(ready); }

    // 窗口关闭时：有下好的新版本就安静地换上，不重启，下次打开就是新版。
    public void ApplyOnExit()
    {
        if (manager is null || ready is null) return;
        try { manager.WaitExitThenApplyUpdates(ready, silent: true, restart: false); }
        catch (Exception) { /* 换不了就留到下次启动：UpdatePendingRestart 还在，关于页仍可手动更新。 */ }
    }

    private void Set(AppUpdateState state) { State = state; Changed?.Invoke(); }

    private sealed record Saved(DateTimeOffset? LastCheck, string? SeenVersion);
    private void Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonSerializer.Deserialize<Saved>(File.ReadAllText(FilePath)) is { } saved)
                (lastCheck, seenVersion) = (saved.LastCheck, saved.SeenVersion);
        }
        catch (JsonException) { }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    private void Save()
    {
        try
        {
            Directory.CreateDirectory(SessionSettings.Root);
            File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(new Saved(lastCheck, seenVersion)));
            File.Move(FilePath + ".tmp", FilePath, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
