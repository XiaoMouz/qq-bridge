using System.ComponentModel;
using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record GroupFilesQuery;
public sealed record GroupFilesPage(ListGroupFilesResponse Response, long Revision);
public sealed record GroupFolderDeletion(string FolderId);
public sealed record GroupFileDeletion(string FileId);
public sealed record GroupFileRename(string FileId, string Name);
public sealed record GroupFileMove(string FileId, string Destination);
public sealed record GroupFolderCreation(string Name);

// 一个实例属于一个群目录。QQ 文件 ID 会随操作变化，删除尝试后必须重新列目录。
public sealed class GroupFilesViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly IUiDispatcher dispatcher;
    private long revision;
    private volatile bool disposed;
    private bool deleting;
    private GroupFilesPage? applied;
    public long GroupId { get; }
    public string FolderId { get; }
    public IReadOnlyList<GroupFolder> Folders { get; private set; } = [];
    public IReadOnlyList<GroupFile> Files { get; private set; } = [];
    public bool NeedsReload { get; private set; } = true;
    public RpcOperationViewModel<GroupFilesQuery, GroupFilesPage> Load { get; }
    public RpcOperationViewModel<GroupFolderDeletion, DeleteGroupFolderResponse> DeleteFolder { get; }
    public RpcOperationViewModel<GroupFileDeletion, DeleteGroupFilesResponse> DeleteFile { get; }
    public RpcOperationViewModel<GroupFileRename, RenameGroupFileResponse> RenameFile { get; }
    public RpcOperationViewModel<GroupFileMove, MoveGroupFilesResponse> MoveFile { get; }
    public RpcOperationViewModel<GroupFolderCreation, CreateGroupFolderResponse> CreateFolder { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public GroupFilesViewModel(long groupId, string folderId, IContactService api, IUiDispatcher dispatcher)
        : this(groupId, folderId, api.ListGroupFilesAsync, api.DeleteGroupFolderAsync, api.DeleteGroupFilesAsync,
            api.RenameGroupFileAsync, api.MoveGroupFilesAsync, api.CreateGroupFolderAsync, dispatcher) { }

    public GroupFilesViewModel(long groupId, string folderId,
        Func<ListGroupFilesRequest, CancellationToken, Task<ListGroupFilesResponse>> list,
        Func<DeleteGroupFolderRequest, CancellationToken, Task<DeleteGroupFolderResponse>> deleteFolder,
        Func<DeleteGroupFilesRequest, CancellationToken, Task<DeleteGroupFilesResponse>> deleteFiles,
        Func<RenameGroupFileRequest, CancellationToken, Task<RenameGroupFileResponse>> rename,
        Func<MoveGroupFilesRequest, CancellationToken, Task<MoveGroupFilesResponse>> move,
        Func<CreateGroupFolderRequest, CancellationToken, Task<CreateGroupFolderResponse>> create, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(groupId);
        GroupId = groupId; FolderId = folderId; this.dispatcher = dispatcher;
        Load = new(async (_, ct) =>
        {
            long start = Interlocked.Read(ref revision);
            return new(await list(new() { GroupId = GroupId, FolderId = FolderId }, ct).ConfigureAwait(false), start);
        }, dispatcher, false);
        DeleteFolder = new((query, ct) => MutateAsync(() =>
        {
            if (string.IsNullOrWhiteSpace(query.FolderId) || !Folders.Any(f => f.Id == query.FolderId))
                throw new InvalidOperationException("请先刷新目录，再选择要删除的文件夹。");
            return new DeleteGroupFolderRequest { GroupId = GroupId, FolderId = query.FolderId };
        }, deleteFolder, ct), dispatcher, true);
        DeleteFile = new((query, ct) => MutateAsync(() =>
        {
            var file = FindFile(query.FileId);
            var request = new DeleteGroupFilesRequest { GroupId = GroupId }; request.FileIds.Add(file.Id); return request;
        }, deleteFiles, ct), dispatcher, true);
        RenameFile = new((query, ct) => MutateAsync(() =>
        {
            var file = FindFile(query.FileId);
            ArgumentException.ThrowIfNullOrWhiteSpace(query.Name);
            return new RenameGroupFileRequest { GroupId = GroupId, FileId = file.Id, FolderId = FolderId,
                NewName = query.Name.Trim(), Name = file.Name, Size = file.Size };
        }, rename, ct), dispatcher, true);
        MoveFile = new((query, ct) => MutateAsync(() =>
        {
            var file = FindFile(query.FileId);
            if (query.Destination == FolderId) throw new ArgumentException("目标目录与当前目录相同。");
            var request = new MoveGroupFilesRequest { GroupId = GroupId, FromFolderId = FolderId, ToFolderId = query.Destination };
            request.FileIds.Add(file.Id); return request;
        }, move, ct), dispatcher, true);
        CreateFolder = new((query, ct) => MutateAsync(() =>
        {
            if (FolderId.Length != 0) throw new InvalidOperationException("请在根目录新建文件夹。");
            ArgumentException.ThrowIfNullOrWhiteSpace(query.Name);
            return new CreateGroupFolderRequest { GroupId = GroupId, Name = query.Name.Trim() };
        }, create, ct), dispatcher, true);
        Load.PropertyChanged += Loaded;
    }

    private GroupFile FindFile(string id) => Files.FirstOrDefault(f => f.Id == id)
        ?? throw new InvalidOperationException("文件已不在当前目录，请刷新后重新选择。");
    private async Task<TResponse> MutateAsync<TRequest, TResponse>(Func<TRequest> prepare,
        Func<TRequest, CancellationToken, Task<TResponse>> execute, CancellationToken ct)
    {
        TRequest request = default!;
        await dispatcher.InvokeAsync(() =>
        {
            ct.ThrowIfCancellationRequested();
            if (disposed || deleting || NeedsReload) throw new InvalidOperationException("请等待当前操作完成并刷新目录。");
            request = prepare();
            deleting = true; Invalidate();
        }).ConfigureAwait(false);
        try { ct.ThrowIfCancellationRequested(); return await execute(request, ct).ConfigureAwait(false); }
        finally { await dispatcher.InvokeAsync(() => { deleting = false; Invalidate(); }).ConfigureAwait(false); }
    }

    public Task<bool> LoadAsync(CancellationToken ct = default) => Load.ExecuteAsync(new(), ct);
    private void Loaded(object? sender, PropertyChangedEventArgs args)
    {
        if (disposed || deleting || Load.State != OperationState.Succeeded || Load.Result is not { } result ||
            ReferenceEquals(applied, result) || result.Revision != Interlocked.Read(ref revision)) return;
        applied = result;
        Folders = result.Response.Folders.Select(f => f.Clone()).ToArray();
        Files = result.Response.Files.Select(f => f.Clone()).ToArray();
        NeedsReload = false; PropertyChanged?.Invoke(this, new(null));
    }
    private void Invalidate()
    {
        Interlocked.Increment(ref revision);
        if (disposed) return;
        NeedsReload = true; Folders = []; Files = [];
        PropertyChanged?.Invoke(this, new(null));
    }
    public void Dispose()
    {
        disposed = true; Load.PropertyChanged -= Loaded; Load.Dispose(); DeleteFolder.Dispose();
        DeleteFile.Dispose(); RenameFile.Dispose(); MoveFile.Dispose(); CreateFolder.Dispose();
    }
}
