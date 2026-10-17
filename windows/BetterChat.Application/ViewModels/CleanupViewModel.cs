using BetterChat.Core;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed record CleanupOptions(uint OlderThanDays, MediaKind? Kind = null);
public sealed record CleanupPlan(Guid Id, PlanCleanupResponse Estimate);
public sealed record CleanupConfirmation(Guid PlanId);

// 预估不是服务端锁定报价；固定请求条件，执行时空间仍可能因共享引用变化而变化。
public sealed class CleanupViewModel : IDisposable
{
    private readonly object gate = new();
    private PlanCleanupRequest? planned;
    private Guid planId;
    private bool busy, disposed;
    public RpcOperationViewModel<CleanupOptions, CleanupPlan> Preview { get; }
    public RpcOperationViewModel<CleanupConfirmation, ExecuteCleanupResponse> Execute { get; }

    public CleanupViewModel(long chatId, IMediaService api, IUiDispatcher dispatcher)
        : this(chatId, api.PlanCleanupAsync, api.ExecuteCleanupAsync, dispatcher) { }

    public CleanupViewModel(long chatId,
        Func<PlanCleanupRequest, CancellationToken, Task<PlanCleanupResponse>> plan,
        Func<ExecuteCleanupRequest, CancellationToken, Task<ExecuteCleanupResponse>> execute, IUiDispatcher dispatcher)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chatId);
        Preview = new(async (options, ct) =>
        {
            Begin();
            try
            {
                lock (gate) { planned = null; planId = Guid.Empty; }
                if (options.OlderThanDays is < 1 or > 36500) throw new ArgumentOutOfRangeException(nameof(options.OlderThanDays));
                if (options.Kind is { } kind && kind is not (MediaKind.Image or MediaKind.Video or MediaKind.Audio or MediaKind.File or MediaKind.Sticker))
                    throw new ArgumentException("不支持的清理类型。");
                var request = new PlanCleanupRequest { ChatId = chatId, OlderThanDays = options.OlderThanDays };
                if (options.Kind is { } selected) request.Kinds.Add(selected);
                var result = await plan(request, ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                lock (gate)
                {
                    if (disposed) throw new OperationCanceledException(ct);
                    planned = request.Clone(); planId = Guid.NewGuid();
                    return new CleanupPlan(planId, result.Clone());
                }
            }
            finally { End(); }
        }, dispatcher, false);
        Execute = new(async (confirmation, ct) =>
        {
            Begin();
            try
            {
                ExecuteCleanupRequest request;
                lock (gate)
                {
                    ct.ThrowIfCancellationRequested();
                    if (planned is null || confirmation.PlanId == Guid.Empty || confirmation.PlanId != planId)
                        throw new InvalidOperationException("清理预估已失效，请重新预估并确认。");
                    request = new ExecuteCleanupRequest { ChatId = planned.ChatId, OlderThanDays = planned.OlderThanDays };
                    request.Kinds.Add(planned.Kinds);
                    // 发出后即消耗确认；超时不能判断是否执行成功，必须重新预估而不能自动重试。
                    planned = null; planId = Guid.Empty;
                }
                return await execute(request, ct).ConfigureAwait(false);
            }
            finally { End(); }
        }, dispatcher, true);
    }
    private void Begin()
    {
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException(nameof(CleanupViewModel));
            if (busy) throw new InvalidOperationException("请等待当前存储操作完成。");
            busy = true;
        }
    }
    private void End() { lock (gate) busy = false; }
    public void Dispose()
    {
        lock (gate) { disposed = true; planned = null; planId = Guid.Empty; }
        Preview.Dispose(); Execute.Dispose();
    }
}
