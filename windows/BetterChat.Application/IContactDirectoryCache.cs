using Qqbridge.V1;

namespace BetterChat.Application;

public sealed record ContactLists(ListFriendsResponse Friends, ListGroupsResponse Groups);

public interface IContactDirectoryCache
{
    Task<ContactLists?> ReadContactsAsync(CancellationToken ct = default);
    Task SaveContactsAsync(ContactLists snapshot, CancellationToken ct = default);
    Task<long> GetContactsRevisionAsync(CancellationToken ct = default);
    Task<bool> TrySaveContactsAsync(ContactLists snapshot, long revision, CancellationToken ct = default);
    Task<ContactLists> RemoveFriendAsync(long userId, CancellationToken ct = default);
}
