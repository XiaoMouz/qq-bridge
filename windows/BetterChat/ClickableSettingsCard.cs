using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;

namespace BetterChat;

// 可点的 SettingsCard。CommunityToolkit 8.2 的 SettingsCard 无障碍 peer 声明支持 Invoke，却没实现 IInvokeProvider，
// 读屏 / UI 自动化一调用就抛「Specified cast is not valid」（2026-10-17 实测）。这里换一个真正实现 Invoke 的 peer。
public sealed partial class ClickableSettingsCard : SettingsCard
{
    public Action? Invoked { get; set; }

    protected override AutomationPeer OnCreateAutomationPeer() => new InvokePeer(this);

    private sealed partial class InvokePeer(ClickableSettingsCard owner) : FrameworkElementAutomationPeer(owner), IInvokeProvider
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;
        protected override string GetClassNameCore() => nameof(SettingsCard);
        protected override string GetNameCore() => base.GetNameCore() is { Length: > 0 } name ? name : owner.Header as string ?? "";
        protected override string GetHelpTextCore() => base.GetHelpTextCore() is { Length: > 0 } help ? help : owner.Description as string ?? "";
        protected override object GetPatternCore(PatternInterface pattern) => pattern == PatternInterface.Invoke ? this : base.GetPatternCore(pattern);
        public void Invoke()
        {
            if (owner.IsEnabled) owner.Invoked?.Invoke();
        }
    }
}
