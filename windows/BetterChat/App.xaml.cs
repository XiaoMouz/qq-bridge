using Microsoft.UI.Xaml;

namespace BetterChat;
public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? window;
    public App()
    {
        InitializeComponent();
        // UI 线程上的未处理异常会让 XAML 直接结束进程（事件日志里只有 0xc000027b），先把异常写下来再退出，方便排查。
        UnhandledException += (_, e) =>
        {
            try
            {
                Directory.CreateDirectory(SessionSettings.Root);
                File.AppendAllText(Path.Combine(SessionSettings.Root, "crash.log"), $"[{DateTimeOffset.Now:O}] {e.Exception}\n\n");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        };
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow(); window.Activate();
    }
}
