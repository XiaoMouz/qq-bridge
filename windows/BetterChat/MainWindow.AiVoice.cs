using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;
using BetterChat.Application.ViewModels;

namespace BetterChat;

public sealed partial class MainWindow
{
    private sealed record VoiceChoice(string Label, AiVoice Voice);

    private async Task ShowAiVoice(long chat)
    {
        if (runtime is not { } session) return;
        var sessionApi = session.Api;
        var ct = lifetime.Token;
        await using var vm = new AiVoiceViewModel(chat, session.ListAiVoicesAsync, session.SendAiVoiceAsync, new UiDispatcher(DispatcherQueue));
        if (!await vm.LoadAsync(ct)) { ct.ThrowIfCancellationRequested(); throw new IOException(vm.Load.Error ?? "语音角色加载失败。"); }
        var response = vm.Load.Result!;
        ct.ThrowIfCancellationRequested();
        if (api != sessionApi) return;
        var voices = response.Categories.SelectMany(category => category.Voices.Select(voice => new VoiceChoice(category.Name + " · " + voice.Name, voice))).ToList();
        if (voices.Count == 0) { await DialogBox("AI 语音", Text("此群当前没有可用的 AI 语音角色。")); return; }

        var panel = new StackPanel { Spacing = 12, MinWidth = 320 };
        var selector = new ComboBox { Header = "语音角色", ItemsSource = voices, DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch, SelectedIndex = 0 };
        var text = new TextBox { Header = "朗读内容", PlaceholderText = "输入想发送的内容", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 100, MaxHeight = 240 };
        var player = new MediaPlayerElement { AreTransportControlsEnabled = true, AutoPlay = false, Height = 80, Visibility = Visibility.Collapsed };
        var preview = ActionButton("试听角色", () =>
        {
            if (selector.SelectedItem is not VoiceChoice selected || selected.Voice.PreviewUrl.Length == 0) return Task.CompletedTask;
            player.MediaPlayer?.Pause();
            player.Source = Windows.Media.Core.MediaSource.CreateFromUri(sessionApi.Transport.ResolveMedia(selected.Voice.PreviewUrl));
            player.Visibility = Visibility.Visible;
            player.MediaPlayer?.Play();
            return Task.CompletedTask;
        });
        selector.SelectionChanged += (_, _) =>
        {
            player.MediaPlayer?.Pause(); player.Source = null; player.Visibility = Visibility.Collapsed;
            preview.IsEnabled = selector.SelectedItem is VoiceChoice v && v.Voice.PreviewUrl.Length > 0;
        };
        preview.IsEnabled = voices[0].Voice.PreviewUrl.Length > 0;
        panel.Children.Add(selector); panel.Children.Add(preview); panel.Children.Add(player); panel.Children.Add(text);
        panel.Children.Add(Text("确认后会以所选角色的语音发送到当前群聊。", 12));
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "AI 语音", Content = panel, PrimaryButtonText = "发送语音", CloseButtonText = "取消", IsPrimaryButtonEnabled = false };
        text.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(text.Text);
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            ct.ThrowIfCancellationRequested();
            if (api != sessionApi || selector.SelectedItem is not VoiceChoice selected) return;
            if (!await vm.SendAsync(selected.Voice.Id, text.Text, ct))
            {
                ct.ThrowIfCancellationRequested();
                throw new IOException((vm.Send.Error ?? "语音提交失败。") + (vm.Send.OutcomeUncertain ? " 请先检查群聊的同步结果，避免重复发送。" : ""));
            }
            ct.ThrowIfCancellationRequested();
            if (runtime != session) return;
            Notice.Severity = InfoBarSeverity.Informational; Notice.Message = "已提交 AI 语音，发送结果将同步到会话。"; Notice.IsOpen = true;
        }
        finally { player.MediaPlayer?.Pause(); player.Source = null; }
    }
}
