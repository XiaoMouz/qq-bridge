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
        Details.Children.Add(Hero(GlyphTile("\uE716"), $"{vm.Directory.Friends.Count} 位好友", $"{vm.Directory.Groups.Count} 个群聊",
            vm.Load.IsBusy ? "正在从 QQ 刷新…" : vm.Load.State == OperationState.Failed ? "刷新失败，显示的是已有列表：" + vm.Load.Error : ""));
        var row = ActionRow(("从 QQ 刷新", "\uE72C", async () =>
        {
            if (runtime != session) return;
            await session.Contacts.LoadAsync(refreshFromQq: true, ct: lifetime.Token);
        }));
        row.IsHitTestVisible = !vm.Load.IsBusy; row.Opacity = vm.Load.IsBusy ? 0.5 : 1;
        Details.Children.Add(row);
        Details.Children.Add(SectionHeader("好友分组"));
        // 点分组只是筛选左侧的好友列表，不离开这一页。
        Task Filter(long? id) { contactCategoryId = id; SelectFilter(0); listSignature = ""; RefreshList(); return Task.CompletedTask; }
        Details.Children.Add(Card("全部好友", null, "\uE716", CardValue(vm.Directory.Friends.Count.ToString()), () => Filter(null)));
        foreach (var category in vm.Directory.Categories)
        {
            var id = category.Id;
            Details.Children.Add(Card(category.Name, category.SpecialCare && category.Name != "特别关心" ? "特别关心" : null, category.SpecialCare ? "\uE734" : "\uE902",
                CardValue(category.UserIds.Count.ToString()), () => Filter(id)));
        }
    }
}
