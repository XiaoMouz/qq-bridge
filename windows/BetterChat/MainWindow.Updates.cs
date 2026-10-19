using BetterChat.Application;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BetterChat;

// 自动更新在界面上的部分：「设置」上的圆点、设置列表里「关于」的副标题、关于页的「版本更新」卡片。
public sealed partial class MainWindow
{
    private AppUpdater updater = null!;
    // 关于页上的卡片（不在关于页时为 null）；状态变了原地改，不重画整页。
    private CommunityToolkit.WinUI.Controls.SettingsCard? updateCard;
    private Button? updateButton;
    private TextBlock? updateNotes;

    private void InitializeUpdates()
    {
        var args = Environment.GetCommandLineArgs();
        int at = Array.IndexOf(args, "-debugUpdateSource");
        updater = new AppUpdater(DispatcherQueue, at >= 0 && at + 1 < args.Length ? args[at + 1] : null);
        updater.Changed += UpdateChanged;
        // 启动和每次回到前台都看一眼是否到了检查时间（6 小时一次）；后台查，不挡界面。
        Activated += (_, e) => { if (e.WindowActivationState != WindowActivationState.Deactivated) _ = updater.CheckIfDueAsync(); };
        Closed += (_, _) => updater.ApplyOnExit();
        UpdateChanged();
    }

    private void UpdateChanged()
    {
        // 正开着关于页时下好的：已经看到了，不再亮圆点（MarkSeen 再触发一次 Changed 时版本相同，直接返回）。
        if (updateCard is not null) updater.MarkSeen();
        UpdateBadge.Visibility = updater.ShowsBadge ? Visibility.Visible : Visibility.Collapsed;
        ToolTipService.SetToolTip(SettingsNavItem, updater.ShowsBadge ? $"设置（新版本 {updater.State.Version}）" : "设置");
        if (section == "settings") { listSignature = ""; RefreshList(); }
        RefreshUpdateCard();
    }

    private string AboutSubtitle => updater.State.Phase == UpdatePhase.Ready ? $"新版本 {updater.State.Version}" : "BetterChat for Windows";

    // 关于页：版本更新卡片 + 下好的新版本的更新说明。
    private void AddUpdateSection()
    {
        Details.Children.Add(SectionHeader("版本更新"));
        updateButton = new Button();
        updateButton.Click += async (_, _) => await Guard(async () =>
        {
            if (updater.State.Phase == UpdatePhase.Ready) updater.RestartNow();
            else await updater.CheckAsync();
        });
        updateCard = Card("当前版本 " + updater.CurrentVersion, null, "", updateButton);
        updateNotes = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Margin = new Thickness(4, 4, 4, 0), Style = Res<Style>("BodyTextBlockStyle") };
        Details.Children.Add(updateCard); Details.Children.Add(updateNotes);
        updateCard.Unloaded += (_, _) => { updateCard = null; updateButton = null; updateNotes = null; };
        RefreshUpdateCard();
        updater.MarkSeen();
    }

    private void RefreshUpdateCard()
    {
        if (updateCard is null || updateButton is null || updateNotes is null) return;
        var state = updater.State;
        updateCard.Description = state.Description(DateTimeOffset.Now);
        bool ready = state.Phase == UpdatePhase.Ready;
        updateButton.Content = ready ? "重启并更新" : "检查更新";
        updateButton.Style = ready ? Res<Style>("AccentButtonStyle") : null;
        updateButton.IsEnabled = ready || state.CanCheck;
        updateButton.Visibility = state.Phase == UpdatePhase.Unavailable ? Visibility.Collapsed : Visibility.Visible;
        // 更新说明由发布流水线按提交标题生成（「• 」开头的几行），这里原样显示。
        updateNotes.Text = ready && !string.IsNullOrWhiteSpace(state.Notes) ? state.Notes.Trim() : "";
        updateNotes.Visibility = updateNotes.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}
