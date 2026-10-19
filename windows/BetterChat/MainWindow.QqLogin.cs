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
        var pill = new ContentControl();
        var statusCard = Card("服务端 QQ", "正在查询…", "\uE77B", pill);
        var error = new TextBlock { Style = Res<Style>("SecondaryCaptionTextBlockStyle"), Foreground = Brush("SystemFillColorCriticalBrush"), TextWrapping = TextWrapping.Wrap };
        // 二维码固定白底黑码，深色模式下也要能扫。
        var picture = new Canvas { Width = 240, Height = 240, Background = new SolidColorBrush(Microsoft.UI.Colors.White) };
        var qrCard = new Border
        {
            Child = picture, Padding = new Thickness(16), Background = new SolidColorBrush(Microsoft.UI.Colors.White), CornerRadius = new CornerRadius(8),
            BorderBrush = Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left, Visibility = Visibility.Collapsed
        };
        Button? refresh = null; string shownUrl = "";
        void Render()
        {
            if (ct.IsCancellationRequested || runtime != session || featurePage != vm) return;
            var state = vm.State;
            statusCard.Description = state is null ? "尚未取得 QQ 状态" : state.LoggedIn ? "已登录，可以收发消息" : "未登录 · " + state.Phase;
            pill.Content = state is null ? null : StatusPill(state.LoggedIn ? "已登录" : "未登录", state.LoggedIn ? Health.Ok : Health.Error);
            error.Text = vm.RefreshQr.Error ?? vm.Load.Error ?? state?.Error ?? "";
            refresh!.IsEnabled = state is { LoggedIn: false } && !vm.RefreshQr.IsBusy;
            refresh.Visibility = state?.LoggedIn == true ? Visibility.Collapsed : Visibility.Visible;
            string address = state is { LoggedIn: false } ? state.QrcodeUrl : "";
            if (address == shownUrl) return;
            shownUrl = address; picture.Children.Clear(); qrCard.Visibility = Visibility.Collapsed;
            if (address.Length == 0) return;
            try
            {
                using var data = QRCodeGenerator.GenerateQrCode(address, QRCodeGenerator.ECCLevel.M);
                var geometry = new GeometryGroup(); double module = 240d / data.ModuleMatrix.Count;
                for (int y = 0; y < data.ModuleMatrix.Count; y++)
                    for (int x = 0; x < data.ModuleMatrix.Count; x++)
                        if (data.ModuleMatrix[y][x]) geometry.Children.Add(new RectangleGeometry { Rect = new Windows.Foundation.Rect(x * module, y * module, module, module) });
                picture.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Fill = new SolidColorBrush(Microsoft.UI.Colors.Black) });
                qrCard.Visibility = Visibility.Visible;
            }
            catch (Exception) { error.Text = "二维码生成失败，请刷新重试。"; }
        }
        refresh = ActionButton("刷新二维码", async () =>
        {
            if (ct.IsCancellationRequested || runtime != session || vm.State?.LoggedIn != false) return;
            await vm.RefreshQr.ExecuteAsync(new(), ct); Render();
        });
        vm.PropertyChanged += (_, _) => Render();
        vm.Load.PropertyChanged += (_, _) => Render(); vm.RefreshQr.PropertyChanged += (_, _) => Render();
        Details.Children.Add(statusCard); Details.Children.Add(error); Details.Children.Add(qrCard); Details.Children.Add(refresh);
        Details.Children.Add(new TextBlock { Text = "用手机 QQ 扫码登录服务端的 QQ。页面只在未登录时查询状态，离开后停止。", Style = Res<Style>("SecondaryCaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
        await vm.ObserveWhileVisibleAsync(ct);
    }
}
