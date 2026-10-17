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
        Detail("存储策略", scope == PolicyScope.Global ? "全局" : scope == PolicyScope.Scene ? scene.ToString() : $"会话 {chat}");
        var vm = new StoragePolicyViewModel(scope, scene, chat, session.ListStoragePoliciesAsync, session.SetStoragePolicyAsync, session.DeleteStoragePolicyAsync, new UiDispatcher(DispatcherQueue)); featurePage = vm;
        if (!await vm.Load.ExecuteAsync(new(), ct))
        { ct.ThrowIfCancellationRequested(); Details.Children.Add(Text(vm.Load.Error ?? "加载失败")); Details.Children.Add(ActionButton("重试", () => ShowStoragePolicy(scope, scene, chat))); return; }
        ct.ThrowIfCancellationRequested();
        if (runtime != session || featurePage != vm) return;
        var policy = vm.Load.Result!;
        Details.Children.Add(Text("留空表示继承上一层。原件保留 -1 为永久、0 为只保留缩略图和预览；冷存储天数 -1 为永不下沉。字节数输入整数，热存储配额 0 为不限。保存会覆盖本层全部字段。", 12));
        TextBox Field(string name, string value)
        { var box = new TextBox { Header = name, Text = value, PlaceholderText = "继承" }; Details.Children.Add(box); return box; }
        var keep = Field("原件保留天数", policy.HasKeepOriginalDays ? policy.KeepOriginalDays.ToString(CultureInfo.InvariantCulture) : "");
        var fetch = Field("自动下载上限（字节）", policy.HasAutoFetchMaxBytes ? policy.AutoFetchMaxBytes.ToString(CultureInfo.InvariantCulture) : "");
        var cold = Field("未访问多少天后下沉", policy.HasColdAfterDays ? policy.ColdAfterDays.ToString(CultureInfo.InvariantCulture) : "");
        var minimum = Field("下沉最小原件（字节）", policy.HasColdMinBytes ? policy.ColdMinBytes.ToString(CultureInfo.InvariantCulture) : "");
        var quota = Field("热存储配额（字节）", policy.HasHotQuotaBytes ? policy.HotQuotaBytes.ToString(CultureInfo.InvariantCulture) : "");
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
        Details.Children.Add(ActionButton("保存本层策略", () => Change(false)));
        Details.Children.Add(ActionButton("删除本层策略，恢复继承", () => Change(true)));
    }
}
