// 从 packages/protocol 自动生成；运行 windows/generate-api.ps1 更新，不手改。
using Qqbridge.V1;
namespace BetterChat.Core;
public interface IAdminService
{
    Task<GetStatusResponse> GetStatusAsync(GetStatusRequest request, CancellationToken ct = default);
    Task<GetQqLoginResponse> GetQqLoginAsync(GetQqLoginRequest request, CancellationToken ct = default);
    Task<RefreshQqLoginQrcodeResponse> RefreshQqLoginQrcodeAsync(RefreshQqLoginQrcodeRequest request, CancellationToken ct = default);
    Task<ListArchiveStatusResponse> ListArchiveStatusAsync(ListArchiveStatusRequest request, CancellationToken ct = default);
    Task<SetDeepArchiveResponse> SetDeepArchiveAsync(SetDeepArchiveRequest request, CancellationToken ct = default);
    Task<FillHolesNowResponse> FillHolesNowAsync(FillHolesNowRequest request, CancellationToken ct = default);
}
public interface IAuthService
{
    Task<LoginResponse> LoginAsync(LoginRequest request, CancellationToken ct = default);
    Task<LogoutResponse> LogoutAsync(LogoutRequest request, CancellationToken ct = default);
    Task<ListDevicesResponse> ListDevicesAsync(ListDevicesRequest request, CancellationToken ct = default);
    Task<RevokeDeviceResponse> RevokeDeviceAsync(RevokeDeviceRequest request, CancellationToken ct = default);
    Task<RegisterPushResponse> RegisterPushAsync(RegisterPushRequest request, CancellationToken ct = default);
}
public interface ICallService
{
    Task<StartCallResponse> StartCallAsync(StartCallRequest request, CancellationToken ct = default);
    Task<GetActiveCallResponse> GetActiveCallAsync(GetActiveCallRequest request, CancellationToken ct = default);
    Task<AnswerCallResponse> AnswerCallAsync(AnswerCallRequest request, CancellationToken ct = default);
    Task<HangupCallResponse> HangupCallAsync(HangupCallRequest request, CancellationToken ct = default);
    Task<ListCallsResponse> ListCallsAsync(ListCallsRequest request, CancellationToken ct = default);
}
public interface IContactService
{
    Task<ListFriendsResponse> ListFriendsAsync(ListFriendsRequest request, CancellationToken ct = default);
    Task<ListGroupsResponse> ListGroupsAsync(ListGroupsRequest request, CancellationToken ct = default);
    Task<GetUserProfileResponse> GetUserProfileAsync(GetUserProfileRequest request, CancellationToken ct = default);
    Task<GetGroupProfileResponse> GetGroupProfileAsync(GetGroupProfileRequest request, CancellationToken ct = default);
    Task<ListGroupMembersResponse> ListGroupMembersAsync(ListGroupMembersRequest request, CancellationToken ct = default);
    Task<RefreshContactsResponse> RefreshContactsAsync(RefreshContactsRequest request, CancellationToken ct = default);
    Task<GetAvatarsResponse> GetAvatarsAsync(GetAvatarsRequest request, CancellationToken ct = default);
    Task<ListGroupNoticesResponse> ListGroupNoticesAsync(ListGroupNoticesRequest request, CancellationToken ct = default);
    Task<ListGroupEssenceResponse> ListGroupEssenceAsync(ListGroupEssenceRequest request, CancellationToken ct = default);
    Task<ListGroupFilesResponse> ListGroupFilesAsync(ListGroupFilesRequest request, CancellationToken ct = default);
    Task<ListGroupAlbumsResponse> ListGroupAlbumsAsync(ListGroupAlbumsRequest request, CancellationToken ct = default);
    Task<ListGroupAlbumMediaResponse> ListGroupAlbumMediaAsync(ListGroupAlbumMediaRequest request, CancellationToken ct = default);
    Task<FetchGroupFileResponse> FetchGroupFileAsync(FetchGroupFileRequest request, CancellationToken ct = default);
    Task<DeleteGroupFilesResponse> DeleteGroupFilesAsync(DeleteGroupFilesRequest request, CancellationToken ct = default);
    Task<MoveGroupFilesResponse> MoveGroupFilesAsync(MoveGroupFilesRequest request, CancellationToken ct = default);
    Task<RenameGroupFileResponse> RenameGroupFileAsync(RenameGroupFileRequest request, CancellationToken ct = default);
    Task<CreateGroupFolderResponse> CreateGroupFolderAsync(CreateGroupFolderRequest request, CancellationToken ct = default);
    Task<DeleteGroupFolderResponse> DeleteGroupFolderAsync(DeleteGroupFolderRequest request, CancellationToken ct = default);
    Task<DeleteFriendResponse> DeleteFriendAsync(DeleteFriendRequest request, CancellationToken ct = default);
}
public interface IDialogService
{
    Task<ListDialogsResponse> ListDialogsAsync(ListDialogsRequest request, CancellationToken ct = default);
    Task<MarkReadResponse> MarkReadAsync(MarkReadRequest request, CancellationToken ct = default);
    Task<SetPinnedResponse> SetPinnedAsync(SetPinnedRequest request, CancellationToken ct = default);
    Task<SetNotifyPolicyResponse> SetNotifyPolicyAsync(SetNotifyPolicyRequest request, CancellationToken ct = default);
    Task<SetMentionAllNotifyResponse> SetMentionAllNotifyAsync(SetMentionAllNotifyRequest request, CancellationToken ct = default);
    Task<SaveDraftResponse> SaveDraftAsync(SaveDraftRequest request, CancellationToken ct = default);
    Task<SetActiveChatResponse> SetActiveChatAsync(SetActiveChatRequest request, CancellationToken ct = default);
    Task<SetTypingResponse> SetTypingAsync(SetTypingRequest request, CancellationToken ct = default);
    Task<OpenChatResponse> OpenChatAsync(OpenChatRequest request, CancellationToken ct = default);
}
public interface IMediaService
{
    Task<PrepareUploadResponse> PrepareUploadAsync(PrepareUploadRequest request, CancellationToken ct = default);
    Task<SignMediaUrlsResponse> SignMediaUrlsAsync(SignMediaUrlsRequest request, CancellationToken ct = default);
    Task<ListMediaUsagesResponse> ListMediaUsagesAsync(ListMediaUsagesRequest request, CancellationToken ct = default);
    Task<GetStorageOverviewResponse> GetStorageOverviewAsync(GetStorageOverviewRequest request, CancellationToken ct = default);
    Task<PlanCleanupResponse> PlanCleanupAsync(PlanCleanupRequest request, CancellationToken ct = default);
    Task<ExecuteCleanupResponse> ExecuteCleanupAsync(ExecuteCleanupRequest request, CancellationToken ct = default);
    Task<ListStoragePoliciesResponse> ListStoragePoliciesAsync(ListStoragePoliciesRequest request, CancellationToken ct = default);
    Task<SetStoragePolicyResponse> SetStoragePolicyAsync(SetStoragePolicyRequest request, CancellationToken ct = default);
    Task<DeleteStoragePolicyResponse> DeleteStoragePolicyAsync(DeleteStoragePolicyRequest request, CancellationToken ct = default);
    Task<GetChatStorageResponse> GetChatStorageAsync(GetChatStorageRequest request, CancellationToken ct = default);
    Task<ListStorageChatsResponse> ListStorageChatsAsync(ListStorageChatsRequest request, CancellationToken ct = default);
    Task<ListStorageItemsResponse> ListStorageItemsAsync(ListStorageItemsRequest request, CancellationToken ct = default);
    Task<RunTieringResponse> RunTieringAsync(RunTieringRequest request, CancellationToken ct = default);
    Task<ListStickersResponse> ListStickersAsync(ListStickersRequest request, CancellationToken ct = default);
    Task<PrepareStickersResponse> PrepareStickersAsync(PrepareStickersRequest request, CancellationToken ct = default);
    Task<AddStickerResponse> AddStickerAsync(AddStickerRequest request, CancellationToken ct = default);
    Task<RequestMediaResponse> RequestMediaAsync(RequestMediaRequest request, CancellationToken ct = default);
}
public interface IMessageService
{
    Task<GetHistoryResponse> GetHistoryAsync(GetHistoryRequest request, CancellationToken ct = default);
    Task<SendMessageResponse> SendMessageAsync(SendMessageRequest request, CancellationToken ct = default);
    Task<RecallMessageResponse> RecallMessageAsync(RecallMessageRequest request, CancellationToken ct = default);
    Task<SearchMessagesResponse> SearchMessagesAsync(SearchMessagesRequest request, CancellationToken ct = default);
    Task<ReactResponse> ReactAsync(ReactRequest request, CancellationToken ct = default);
    Task<GetForwardResponse> GetForwardAsync(GetForwardRequest request, CancellationToken ct = default);
    Task<ListSharedMediaResponse> ListSharedMediaAsync(ListSharedMediaRequest request, CancellationToken ct = default);
    Task<ForwardMessagesResponse> ForwardMessagesAsync(ForwardMessagesRequest request, CancellationToken ct = default);
    Task<ListUnreadMentionsResponse> ListUnreadMentionsAsync(ListUnreadMentionsRequest request, CancellationToken ct = default);
    Task<MarkMentionsSeenResponse> MarkMentionsSeenAsync(MarkMentionsSeenRequest request, CancellationToken ct = default);
    Task<TranscribeVoiceResponse> TranscribeVoiceAsync(TranscribeVoiceRequest request, CancellationToken ct = default);
    Task<ListAiVoicesResponse> ListAiVoicesAsync(ListAiVoicesRequest request, CancellationToken ct = default);
    Task<SendAiVoiceResponse> SendAiVoiceAsync(SendAiVoiceRequest request, CancellationToken ct = default);
    Task<ListReactionUsersResponse> ListReactionUsersAsync(ListReactionUsersRequest request, CancellationToken ct = default);
}
public interface ISyncService
{
    Task<GetStateResponse> GetStateAsync(GetStateRequest request, CancellationToken ct = default);
    Task<GetDifferenceResponse> GetDifferenceAsync(GetDifferenceRequest request, CancellationToken ct = default);
    Task<GetChatDifferenceResponse> GetChatDifferenceAsync(GetChatDifferenceRequest request, CancellationToken ct = default);
    Task<GetChatDifferencesResponse> GetChatDifferencesAsync(GetChatDifferencesRequest request, CancellationToken ct = default);
    IAsyncEnumerable<SubscribeResponse> SubscribeAsync(SubscribeRequest request, CancellationToken ct = default);
}
public interface IBridgeApi : IAdminService, IAuthService, ICallService, IContactService, IDialogService, IMediaService, IMessageService, ISyncService { }
