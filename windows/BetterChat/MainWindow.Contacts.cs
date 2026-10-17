using System.ComponentModel;
using BetterChat.Application.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace BetterChat;

public sealed partial class MainWindow
{
    private void ContactsChanged(object? sender, PropertyChangedEventArgs args)
    {
        contactRevision++;
        if (section != "contacts") return;
        listSignature = ""; QueueRefresh();
        if (contactsOverview) ShowContactsOverview();
    }
    private void ShowContactsOverview()
    {
        var session = runtime;
        if (session is null) return;
        var vm = session.Contacts;
        Detail("联系人", vm.Directory.IsCached ? "本地缓存" : "已获取联系人列表");
        contactsOverview = true;
        Details.Children.Add(Text($"{vm.Directory.Friends.Count} 位好友 · {vm.Directory.Groups.Count} 个群"));
        if (vm.Load.IsBusy) Details.Children.Add(Text("正在刷新联系人…"));
        if (vm.Load.State == OperationState.Failed) Details.Children.Add(Text("刷新失败，保留已有列表：" + vm.Load.Error));
        var refresh = ActionButton("从 QQ 刷新联系人", async () =>
        {
            if (runtime != session) return;
            await session.Contacts.LoadAsync(refreshFromQq: true, ct: lifetime.Token);
        });
        refresh.IsEnabled = !vm.Load.IsBusy;
        Details.Children.Add(refresh);
        Details.Children.Add(ActionButton("全部好友", () =>
        {
            contactCategoryId = null; SelectFilter(0); listSignature = ""; RefreshList();
            return Task.CompletedTask;
        }));
        foreach (var category in vm.Directory.Categories)
        {
            var id = category.Id;
            Details.Children.Add(ActionButton($"{(category.SpecialCare ? "特别关心 · " : "")}{category.Name}（{category.UserIds.Count}）", () =>
            {
                contactCategoryId = id; SelectFilter(0); listSignature = ""; RefreshList();
                return Task.CompletedTask;
            }));
        }
    }
}
