using System.ComponentModel;

namespace BetterChat.Application;

public sealed record RecordedVoice(byte[] Audio, TimeSpan Duration, string Name = "voice.m4a", string Mime = "audio/mp4");
public interface IVoiceRecorder : IAsyncDisposable
{
    Task StartAsync(CancellationToken ct);
    Task<RecordedVoice> FinishAsync(CancellationToken ct);
    Task CancelAsync();
}
public enum VoiceRecordingState { Idle, Starting, Recording, Stopping, Ready, Failed, Disposed }

// 由 UI 上下文拥有；设备初始化需回到调用线程，不能通过 Task.Run 绕开系统授权流程。
public sealed class VoiceRecordingSession(IVoiceRecorder recorder, TimeProvider? timeProvider = null) : INotifyPropertyChanged, IAsyncDisposable
{
    public static readonly TimeSpan MaximumDuration = TimeSpan.FromSeconds(60);
    private readonly SemaphoreSlim serial = new(1, 1);
    private CancellationTokenSource? operation;
    private CancellationTokenSource? limit;
    private bool disposed;
    private Task? disposing;
    public VoiceRecordingState State { get; private set; }
    public RecordedVoice? Recording { get; private set; }
    public string? Error { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;
    private void Publish(VoiceRecordingState state) { State = state; PropertyChanged?.Invoke(this, new(null)); }
    public async Task StartAsync(CancellationToken ct = default)
    {
        await serial.WaitAsync(ct);
        try
        {
            if (disposed || State is VoiceRecordingState.Starting or VoiceRecordingState.Recording or VoiceRecordingState.Stopping) return;
            operation?.Dispose(); operation = CancellationTokenSource.CreateLinkedTokenSource(ct);
            Recording = null; Error = null; Publish(VoiceRecordingState.Starting);
            try
            {
                await recorder.StartAsync(operation.Token); operation.Token.ThrowIfCancellationRequested();
                Publish(VoiceRecordingState.Recording);
                limit = new(); _ = StopAtLimitAsync(limit.Token);
            }
            catch (Exception error)
            {
                var cleanup = await ReleaseAsync();
                if (cleanup is null && error is OperationCanceledException && operation.IsCancellationRequested) Publish(VoiceRecordingState.Idle);
                else { Error = error.Message + (cleanup is null ? "" : "；停止录音失败：" + cleanup); Publish(VoiceRecordingState.Failed); }
            }
        }
        finally { serial.Release(); }
    }
    private async Task StopAtLimitAsync(CancellationToken ct)
    {
        try { await Task.Delay(MaximumDuration, timeProvider ?? TimeProvider.System, ct); await FinishAsync(ct); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    }
    public async Task FinishAsync(CancellationToken ct = default)
    {
        await serial.WaitAsync(ct);
        try
        {
            if (disposed || State != VoiceRecordingState.Recording) return;
            // 到时自动停止仅准备录音，仍需用户按发送，不能在计时结束时悄悄发消息。
            Publish(VoiceRecordingState.Stopping);
            try
            {
                var voice = await recorder.FinishAsync(operation!.Token); operation.Token.ThrowIfCancellationRequested();
                if (voice.Audio.Length == 0 || voice.Duration < TimeSpan.FromSeconds(1)) throw new IOException("录音不足一秒，请重新录制。");
                Recording = voice; Publish(VoiceRecordingState.Ready);
            }
            catch (Exception error)
            {
                var cleanup = await ReleaseAsync(); Recording = null;
                if (cleanup is null && error is OperationCanceledException && operation!.IsCancellationRequested) Publish(VoiceRecordingState.Idle);
                else { Error = error.Message + (cleanup is null ? "" : "；停止录音失败：" + cleanup); Publish(VoiceRecordingState.Failed); }
            }
            finally { limit?.Cancel(); limit?.Dispose(); limit = null; }
        }
        finally { serial.Release(); }
    }
    public async Task CancelAsync()
    {
        operation?.Cancel(); limit?.Cancel();
        await serial.WaitAsync();
        try { Error = await ReleaseAsync(); Recording = null; if (!disposed) Publish(Error is null ? VoiceRecordingState.Idle : VoiceRecordingState.Failed); }
        finally { serial.Release(); }
    }
    private async Task<string?> ReleaseAsync()
    {
        try { await recorder.CancelAsync(); return null; }
        catch (Exception error) { return error.Message; }
    }
    public ValueTask DisposeAsync() => new(disposing ??= DisposeCoreAsync());
    private async Task DisposeCoreAsync()
    {
        disposed = true;
        try { await CancelAsync(); await recorder.DisposeAsync(); }
        finally { operation?.Dispose(); limit?.Dispose(); Recording = null; Publish(VoiceRecordingState.Disposed); }
    }
}
