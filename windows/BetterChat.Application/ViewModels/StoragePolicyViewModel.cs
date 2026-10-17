using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record StoragePolicyQuery;
public sealed record StoragePolicyValues(int? KeepDays, ulong? AutoFetchBytes, int? ColdDays, ulong? ColdMinBytes, ulong? HotQuotaBytes);

// 固定作用域；字段缺席表示继承，不能把 optional 的缺席和显式 0 混为一谈。
public sealed class StoragePolicyViewModel : IDisposable
{
    private int busy;
    public RpcOperationViewModel<StoragePolicyQuery, StoragePolicy> Load { get; }
    public RpcOperationViewModel<StoragePolicyValues, SetStoragePolicyResponse> Save { get; }
    public RpcOperationViewModel<StoragePolicyQuery, DeleteStoragePolicyResponse> Reset { get; }
    public StoragePolicyViewModel(PolicyScope scope, Scene scene, long chatId, IMediaService api, IUiDispatcher dispatcher)
        : this(scope, scene, chatId, api.ListStoragePoliciesAsync, api.SetStoragePolicyAsync, api.DeleteStoragePolicyAsync, dispatcher) { }

    public StoragePolicyViewModel(PolicyScope scope, Scene scene, long chatId,
        Func<ListStoragePoliciesRequest, CancellationToken, Task<ListStoragePoliciesResponse>> list,
        Func<SetStoragePolicyRequest, CancellationToken, Task<SetStoragePolicyResponse>> set,
        Func<DeleteStoragePolicyRequest, CancellationToken, Task<DeleteStoragePolicyResponse>> delete, IUiDispatcher dispatcher)
    {
        if (scope is not (PolicyScope.Global or PolicyScope.Scene or PolicyScope.Chat)
            || (scope == PolicyScope.Scene && scene is not (Scene.Friend or Scene.Group or Scene.Temp))
            || (scope == PolicyScope.Chat && chatId <= 0)) throw new ArgumentException("策略作用域无效。");
        var target = new StoragePolicy { Scope = scope, Scene = scope == PolicyScope.Scene ? scene : Scene.Unspecified, ChatId = scope == PolicyScope.Chat ? chatId : 0 };
        Load = new((_, ct) => Exclusive(async () =>
        {
            var result = await list(new(), ct).ConfigureAwait(false);
            var matches = result.Policies.Where(p => p.Scope == target.Scope && p.Scene == target.Scene && p.ChatId == target.ChatId).ToArray();
            if (matches.Length > 1) throw new IOException("服务端返回重复作用域策略。");
            return matches.FirstOrDefault()?.Clone() ?? target.Clone();
        }), dispatcher, false);
        Save = new((values, ct) => Exclusive(() =>
        {
            if (values.KeepDays < -1 || values.ColdDays < -1) throw new ArgumentException("天数须为 -1、0 或正整数。");
            // 后端持久化前使用 Number.isSafeInteger 校验，不能仅依赖 proto uint64 上限。
            if (values.AutoFetchBytes > (ulong)MessageIdentity.MaxValue || values.ColdMinBytes > (ulong)MessageIdentity.MaxValue || values.HotQuotaBytes > (ulong)MessageIdentity.MaxValue)
                throw new ArgumentException("字节数超过后端支持的安全整数范围。");
            var policy = target.Clone();
            if (values.KeepDays is { } keep) policy.KeepOriginalDays = keep;
            if (values.AutoFetchBytes is { } fetch) policy.AutoFetchMaxBytes = fetch;
            if (values.ColdDays is { } cold) policy.ColdAfterDays = cold;
            if (values.ColdMinBytes is { } minimum) policy.ColdMinBytes = minimum;
            if (values.HotQuotaBytes is { } quota) policy.HotQuotaBytes = quota;
            return set(new() { Policy = policy }, ct);
        }), dispatcher, true);
        Reset = new((_, ct) => Exclusive(() => delete(new() { Scope = target.Scope, Scene = target.Scene, ChatId = target.ChatId }, ct)), dispatcher, true);
    }
    private async Task<T> Exclusive<T>(Func<Task<T>> run)
    {
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) throw new InvalidOperationException("请等待当前策略操作完成。");
        try { return await run().ConfigureAwait(false); }
        finally { Volatile.Write(ref busy, 0); }
    }
    public void Dispose() { Load.Dispose(); Save.Dispose(); Reset.Dispose(); }
}
