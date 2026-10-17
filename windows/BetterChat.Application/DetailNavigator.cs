using CommunityToolkit.Mvvm.ComponentModel;

namespace BetterChat.Application;

// Key 标识「同一个页面」：重复进入同一个 Key（刷新、重试、同会话内跳到某条消息）只替换当前页，不入栈。
public sealed record DetailDestination(string Key, Func<Task> Show);

// 右栏的页面栈。左侧导航切换、列表选中、点通知是根导航（清栈）；在右栏里点进去的是下钻（入栈）。
// 页面本身仍由 Show 重新构建，栈里只存怎么回到那一页，不缓存控件，所以返回时会重新加载数据。
public sealed class DetailNavigator : ObservableObject
{
    // 下钻很少超过五六层；设上限只是防止某条路径反复互相跳转时栈无限增长。
    public const int MaxDepth = 32;
    private readonly List<DetailDestination> back = [];

    public DetailDestination? Current { get; private set; }
    public bool CanGoBack => back.Count > 0;
    public int Depth => back.Count;

    public Task ResetAsync(DetailDestination destination)
    {
        back.Clear();
        return Show(destination);
    }

    public Task NavigateAsync(DetailDestination destination)
    {
        if (Current is { } current && current.Key != destination.Key)
        {
            // 目标已经在栈里（例如 聊天 → 资料 → 发消息 回到同一个聊天）就退回到它，而不是再压一层。
            int existing = back.FindLastIndex(d => d.Key == destination.Key);
            if (existing >= 0) back.RemoveRange(existing, back.Count - existing);
            else
            {
                back.Add(current);
                if (back.Count > MaxDepth) back.RemoveAt(0);
            }
        }
        return Show(destination);
    }

    public async Task<bool> GoBackAsync()
    {
        if (back.Count == 0) return false;
        var destination = back[^1];
        back.RemoveAt(back.Count - 1);
        await Show(destination);
        return true;
    }

    public void Clear()
    {
        back.Clear(); Current = null;
        OnPropertyChanged(nameof(Current)); OnPropertyChanged(nameof(CanGoBack));
    }

    private Task Show(DetailDestination destination)
    {
        // 先更新状态再构建页面：页面构建失败时仍停在目标页（页面自己显示错误和重试），返回键照常可用。
        Current = destination;
        OnPropertyChanged(nameof(Current)); OnPropertyChanged(nameof(CanGoBack));
        return destination.Show();
    }
}
