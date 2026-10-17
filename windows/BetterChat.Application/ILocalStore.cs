using Google.Protobuf;
using Qqbridge.V1;

namespace BetterChat.Core;

// 应用层依赖事务语义，不依赖 SQLite 连接或 WinUI 调度器。
public interface ILocalStore : IDisposable
{
    event Action? Changed;
    event Action? DialogsChanged;
    event Action? PeersChanged;
    BetterChat.Application.DialogDirectorySnapshot ReadDialogDirectory(long knownPeerRevision = -1);
    BetterChat.Application.TimelineSnapshot ReadTimeline(BetterChat.Application.TimelineQuery query);
    long PeerRevision { get; }
    long DialogRevision { get; }
    long Cursor(string key = "global");
    List<T> Read<T>(string kind, MessageParser<T> parser, long? chat = null) where T : IMessage<T>;
    List<T> ReadWindow<T>(string kind, MessageParser<T> parser, long chat, IEnumerable<string> keys, long? newerThan) where T : IMessage<T>;
    List<Dialog> Dialogs { get; }
    Dialog? ReadDialog(long chat);
    List<Peer> Peers { get; }
    List<Message> Messages(long chat);
    void Apply(Difference difference);
    void ApplyChat(long chat, long pts, IEnumerable<Message> messages, IEnumerable<ChatEvent> events, bool reset = false);
    void MergeHistory(long chat, IEnumerable<Message> messages, IEnumerable<ChatEvent> events);
    void MergeHistoryPage(long chat, GetHistoryResponse page, bool latest);
    void SaveLocalDraft(SaveDraftRequest request);
    SaveDraftRequest? ReadLocalDraft(long chat);
    void ConfirmLocalDraft(long chat);
    void SavePending(SendMessageRequest request);
    GetHistoryResponse? LatestHistory(long chat);
    void SaveLatestHistory(long chat, GetHistoryResponse page);
    bool TryApplyFirstScreen(long chat, GetHistoryResponse page, bool reset);
    void AcceptPending(OutboxEntry entry);
    void RemovePending(long id);
    BetterChat.Application.ContactLists? ReadContacts();
    void SaveContacts(BetterChat.Application.ContactLists snapshot);
    long ContactsRevision { get; }
    bool TrySaveContacts(BetterChat.Application.ContactLists snapshot, long revision);
    BetterChat.Application.ContactLists RemoveFriend(long userId);
    void Reset();
}
