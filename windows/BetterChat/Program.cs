using Velopack;

namespace BetterChat;

// 自己的入口（csproj 里 DISABLE_XAML_GENERATED_MAIN）：Velopack 的安装、更新、卸载钩子要在最前面处理，
// 带这些参数启动时它会做完对应的事直接退出，不会进到界面；之后照常走 WinUI 生成的启动流程。
public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build().Run();
        XamlGeneratedProgram.XamlGeneratedMain();
    }
}
