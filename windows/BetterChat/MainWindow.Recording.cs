using BetterChat.Application;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private VoiceRecordingSession? recordingSession;
    private async Task ShowVoiceRecording(long chat)
    {
        if (runtime is not { } session || recordingSession is not null) return;
        var ct = lifetime.Token;
        await using var recorder = new VoiceRecordingSession(new WindowsVoiceRecorder());
        recordingSession = recorder;
        var status = Text("点击开始后使用麦克风，最长录制 60 秒。停止后再确认发送。", 12);
        var start = new Button { Content = "开始录音" }; var stop = new Button { Content = "停止录音", IsEnabled = false };
        var content = new StackPanel { Spacing = 12, MinWidth = 320 }; content.Children.Add(status); content.Children.Add(start); content.Children.Add(stop);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "录制语音", Content = content, PrimaryButtonText = "发送语音", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        VoiceMessageSendViewModel? senderModel = null;
        using var dialogLifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            start.IsEnabled = recorder.State is VoiceRecordingState.Idle or VoiceRecordingState.Failed or VoiceRecordingState.Ready;
            stop.IsEnabled = recorder.State == VoiceRecordingState.Recording;
            dialog.IsPrimaryButtonEnabled = recorder.State == VoiceRecordingState.Ready;
            status.Text = recorder.State switch
            {
                VoiceRecordingState.Starting => "正在请求麦克风…",
                VoiceRecordingState.Recording => "正在录音，最多 60 秒；停止后可发送。",
                VoiceRecordingState.Stopping => "正在结束录音…",
                VoiceRecordingState.Ready => $"已录制 {recorder.Recording!.Duration.TotalSeconds:F1} 秒，可发送或重新录制。",
                VoiceRecordingState.Failed => recorder.Error ?? "录音失败，请检查麦克风权限和设备。",
                _ => "点击开始录音。"
            };
        }
        recorder.PropertyChanged += Changed;
        start.Click += async (_, _) => await Guard(() => recorder.StartAsync(ct));
        stop.Click += async (_, _) => await Guard(() => recorder.FinishAsync(ct));
        using var cancelled = ct.Register(() => DispatcherQueue.TryEnqueue(() => dialog.Hide()));
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                if (runtime != session || dialogLifetime.IsCancellationRequested || recorder.Recording is not { } voice) return;
                senderModel ??= new VoiceMessageSendViewModel(chat, RandomId(), voice, session.UploadMediaAsync, session.SendMessageAsync, new UiDispatcher(DispatcherQueue));
                start.IsEnabled = stop.IsEnabled = dialog.IsPrimaryButtonEnabled = false;
                status.Text = "正在上传并提交语音…";
                bool success = await senderModel.SendAsync(dialogLifetime.Token);
                if (runtime != session || dialogLifetime.IsCancellationRequested) return;
                if (success) args.Cancel = false;
                else
                {
                    status.Text = (senderModel.Send.Error ?? "发送未完成。") + " 录音已保留，可重试；已提交的请求会沿用原消息标识。";
                    dialog.PrimaryButtonText = "重试发送"; dialog.IsPrimaryButtonEnabled = true;
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception error) { status.Text = error.Message; dialog.IsPrimaryButtonEnabled = true; }
            finally { deferral.Complete(); }
        };
        dialog.Closing += (_, _) => dialogLifetime.Cancel();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            dialogLifetime.Cancel();
            recorder.PropertyChanged -= Changed;
            try { if (senderModel is not null) await senderModel.DisposeAsync(); }
            finally
            {
                await recorder.DisposeAsync();
                if (ReferenceEquals(recordingSession, recorder)) recordingSession = null;
            }
        }
    }
}
