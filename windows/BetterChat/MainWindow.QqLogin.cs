using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using QRCoder;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowQqLogin()
    {
        if (runtime is not { } session) return;
        var ct = NewPage(); Detail("QQ 登录状态", "这是服务端 QQ 的登录状态，与 QQ Bridge 密码登录独立。");
        var vm = new QqLoginViewModel(session.GetQqLoginAsync, session.RefreshQqLoginQrcodeAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        var status = Text("正在查询…"); var error = Text("", 12);
        var picture = new Canvas { Width = 260, Height = 260, Background = new SolidColorBrush(Microsoft.UI.Colors.White), Visibility = Visibility.Collapsed };
        Button? refresh = null; string shownUrl = "";
        void Render()
        {
            if (ct.IsCancellationRequested || runtime != session || featurePage != vm) return;
            var state = vm.State;
            status.Text = state is null ? "尚未取得 QQ 状态" : state.LoggedIn ? "QQ 已登录" : "QQ 未登录 · " + state.Phase;
            error.Text = vm.RefreshQr.Error ?? vm.Load.Error ?? state?.Error ?? "";
            refresh!.IsEnabled = state is { LoggedIn: false } && !vm.RefreshQr.IsBusy;
            string address = state is { LoggedIn: false } ? state.QrcodeUrl : "";
            if (address == shownUrl) return;
            shownUrl = address; picture.Children.Clear(); picture.Visibility = Visibility.Collapsed;
            if (address.Length == 0) return;
            try
            {
                using var data = QRCodeGenerator.GenerateQrCode(address, QRCodeGenerator.ECCLevel.M);
                var geometry = new GeometryGroup(); double module = 260d / data.ModuleMatrix.Count;
                for (int y = 0; y < data.ModuleMatrix.Count; y++)
                    for (int x = 0; x < data.ModuleMatrix.Count; x++)
                        if (data.ModuleMatrix[y][x]) geometry.Children.Add(new RectangleGeometry { Rect = new Windows.Foundation.Rect(x * module, y * module, module, module) });
                picture.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Fill = new SolidColorBrush(Microsoft.UI.Colors.Black) });
                picture.Visibility = Visibility.Visible;
            }
            catch (Exception) { error.Text = "二维码生成失败，请刷新重试。"; }
        }
        refresh = ActionButton("刷新 QQ 登录二维码", async () =>
        {
            if (ct.IsCancellationRequested || runtime != session || vm.State?.LoggedIn != false) return;
            await vm.RefreshQr.ExecuteAsync(new(), ct); Render();
        });
        vm.PropertyChanged += (_, _) => Render();
        vm.Load.PropertyChanged += (_, _) => Render(); vm.RefreshQr.PropertyChanged += (_, _) => Render();
        Details.Children.Add(status); Details.Children.Add(error); Details.Children.Add(picture); Details.Children.Add(refresh);
        Details.Children.Add(Text("二维码由你自行扫描；页面只在未登录期间查询状态，离开后停止。", 12));
        await vm.ObserveWhileVisibleAsync(ct);
    }
}
