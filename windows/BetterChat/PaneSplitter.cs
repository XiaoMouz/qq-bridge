using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace BetterChat;

// 列表右边线上的拖动条。ProtectedCursor 只能在子类里设置，所以单独一个类；拖动逻辑在 MainWindow。
public sealed partial class PaneSplitter : Grid
{
    public PaneSplitter()
    {
        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
    }
}
