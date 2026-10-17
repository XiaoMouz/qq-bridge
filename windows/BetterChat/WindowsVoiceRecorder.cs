using System.Diagnostics;
using BetterChat.Application;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;

namespace BetterChat;

internal sealed class WindowsVoiceRecorder : IVoiceRecorder
{
    private MediaCapture? capture;
    private InMemoryRandomAccessStream? audio;
    private readonly Stopwatch elapsed = new();
    private bool recording;
    public async Task StartAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        await CancelAsync();
        capture = new MediaCapture();
        try
        {
            await capture.InitializeAsync(new MediaCaptureInitializationSettings { StreamingCaptureMode = StreamingCaptureMode.Audio, MediaCategory = MediaCategory.Speech });
            ct.ThrowIfCancellationRequested();
            audio = new InMemoryRandomAccessStream();
            var profile = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Low);
            profile.Audio.ChannelCount = 1; profile.Audio.SampleRate = 24000; profile.Audio.Bitrate = 32000;
            await capture.StartRecordToStreamAsync(profile, audio); recording = true; elapsed.Restart();
            ct.ThrowIfCancellationRequested();
        }
        catch { await CancelAsync(); throw; }
    }
    public async Task<RecordedVoice> FinishAsync(CancellationToken ct)
    {
        if (capture is null || audio is null || !recording) throw new InvalidOperationException("麦克风尚未开始录音。");
        try
        {
            var duration = elapsed.Elapsed;
            await capture.StopRecordAsync(); recording = false; elapsed.Stop(); ct.ThrowIfCancellationRequested();
            if (audio.Size > 8 * 1024 * 1024) throw new IOException("录音数据异常过大，请重新录制。");
            audio.Seek(0);
            using var source = audio.AsStreamForRead(); using var copy = new MemoryStream();
            await source.CopyToAsync(copy, ct);
            return new(copy.ToArray(), duration);
        }
        finally { await CancelAsync(); }
    }
    public async Task CancelAsync()
    {
        try { if (recording && capture is not null) await capture.StopRecordAsync(); }
        finally { recording = false; elapsed.Reset(); capture?.Dispose(); capture = null; audio?.Dispose(); audio = null; }
    }
    public async ValueTask DisposeAsync() => await CancelAsync();
}
