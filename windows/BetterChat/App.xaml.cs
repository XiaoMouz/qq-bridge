using Microsoft.UI.Xaml;

namespace BetterChat;
public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? window;
    public App() { InitializeComponent(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow(); window.Activate();
    }
}
