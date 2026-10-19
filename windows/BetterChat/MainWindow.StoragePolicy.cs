using System.Globalization;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Qqbridge.V1;

namespace BetterChat;

public sealed partial class MainWindow
{
    private async Task ShowStoragePolicy(PolicyScope scope, Scene scene = Scene.Unspecified, long chat = 0)
    {
        var session = runtime; if (session is null) return;
        var ct = NewPage();
        Detail("存储策略", scope == PolicyScope.Global ? "全局（所有会话的默认值）" : scope == PolicyScope.Scene ? (scene switch { Scene.Friend => "私聊", Scene.Group => "群聊", Scene.Temp => "临时会话", _ => scene.ToString() }) + "（覆盖全局）" : PeerNameForChat(chat) + "（覆盖类型和全局）");
        var vm = new StoragePolicyViewModel(scope, scene, chat, session.ListStoragePoliciesAsync, session.SetStoragePolicyAsync, session.DeleteStoragePolicyAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        if (!await vm.Load.ExecuteAsync(new(), ct))
        { ct.ThrowIfCancellationRequested(); PageError("存储策略加载失败", vm.Load.Error, () => ShowStoragePolicy(scope, scene, chat)); return; }
        ct.ThrowIfCancellationRequested();
        if (runtime != session || featurePage != vm) return;
        var policy = vm.Load.Result!;
        var actions = new StackPanel();
        Details.Children.Add(actions);
        Details.Children.Add(new Microsoft.UI.Xaml.Controls.TextBlock
        {
            Text = "留空表示继承上一层。保存会覆盖本层全部字段。", Style = Res<Microsoft.UI.Xaml.Style>("SecondaryCaptionTextBlockStyle"), TextWrapping = Microsoft.UI.Xaml.TextWrapping.Wrap
        });
        TextBox Field(string name, string description, string glyph, string value)
        {
            var box = new TextBox { Text = value, PlaceholderText = "继承", Width = 160 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, name);
            Details.Children.Add(Card(name, description, glyph, box)); return box;
        }
        var keep = Field("原件保留天数", "-1 永久保留；0 只保留缩略图和预览", "\uE823", policy.HasKeepOriginalDays ? policy.KeepOriginalDays.ToString(CultureInfo.InvariantCulture) : "");
        var fetch = Field("自动下载上限（字节）", "超过这个大小的原件不自动下载，用到时再取", "\uE896", policy.HasAutoFetchMaxBytes ? policy.AutoFetchMaxBytes.ToString(CultureInfo.InvariantCulture) : "");
        var cold = Field("未访问多少天后下沉", "-1 永不下沉到冷存储", "\uE81E", policy.HasColdAfterDays ? policy.ColdAfterDays.ToString(CultureInfo.InvariantCulture) : "");
        var minimum = Field("下沉最小原件（字节）", "比这个小的原件留在热存储", "\uE81E", policy.HasColdMinBytes ? policy.ColdMinBytes.ToString(CultureInfo.InvariantCulture) : "");
        var quota = Field("热存储配额（字节）", "0 表示不限", "\uEDA2", policy.HasHotQuotaBytes ? policy.HotQuotaBytes.ToString(CultureInfo.InvariantCulture) : "");
        static int? Days(TextBox input) => string.IsNullOrWhiteSpace(input.Text) ? null
            : int.TryParse(input.Text.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out int value) ? value : throw new ArgumentException("天数必须是整数。");
        static ulong? BytesValue(TextBox input) => string.IsNullOrWhiteSpace(input.Text) ? null
            : ulong.TryParse(input.Text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out ulong value) ? value : throw new ArgumentException("字节数必须是非负整数。");
        bool busy = false;
        async Task Change(bool reset)
        {
            if (busy || ct.IsCancellationRequested || runtime != session) return;
            busy = true;
            try
            {
                bool success = reset ? await vm.Reset.ExecuteAsync(new(), ct)
                    : await vm.Save.ExecuteAsync(new(Days(keep), BytesValue(fetch), Days(cold), BytesValue(minimum), BytesValue(quota)), ct);
                ct.ThrowIfCancellationRequested();
                if (runtime != session || featurePage != vm) return;
                if (!success) throw new IOException((reset ? vm.Reset.Error : vm.Save.Error) ?? "结果待确认，请重新加载策略。");
                await ShowStoragePolicy(scope, scene, chat);
            }
            finally { busy = false; }
        }
        actions.Children.Add(ActionRow(("保存", "\uE74E", () => Change(false)), ("删除本层，恢复继承", "\uE7A7", () => Change(true))));
    }
}
