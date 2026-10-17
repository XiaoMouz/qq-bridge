using BetterChat.Core;
using BetterChat.Application.ViewModels;
using Qqbridge.V1;

namespace BetterChat.Application;

public interface ICallAudioSession
{
    // 权限与设备检查必须先于服务器呼出/接听；不支持的平台应在这里失败。
    Task PrepareAsync(CancellationToken ct);
    Task JoinAsync(Uri server, string token, string room, CancellationToken ct);
    Task LeaveAsync(CancellationToken ct);
}

// 一个账号只拥有一个本机音频会话。平台实现必须支持取消和幂等 Leave。
public sealed class CallCoordinator(ICallService api, ICallAudioSession audio, CallStateViewModel state)
{
    private readonly SemaphoreSlim serial = new(1);
    private readonly object gate = new();
    private readonly HashSet<string> ended = new(StringComparer.Ordinal);
    private CancellationTokenSource? joining;
    private string? joiningId;
    private string? connectedId;

    public Task<Call> StartAsync(long peerUin, CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(peerUin);
        return ConnectAsync(async token =>
        {
            var response = await api.StartCallAsync(new() { PeerUin = peerUin }, token).ConfigureAwait(false);
            return new Connection(response.Call, response.LivekitUrl, response.LivekitToken, response.Room);
        }, ct);
    }
    public Task<Call> AnswerAsync(string callId, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(callId);
        return ConnectAsync(async token =>
        {
            var response = await api.AnswerCallAsync(new() { CallId = callId }, token).ConfigureAwait(false);
            if (response.Call?.Id != callId) throw new IOException("接听响应的通话 ID 不匹配。");
            return new Connection(response.Call, response.LivekitUrl, response.LivekitToken, response.Room);
        }, ct, callId);
    }
    private async Task<Call> ConnectAsync(Func<CancellationToken, Task<Connection>> request, CancellationToken ct, string? requestedCallId = null)
    {
        await serial.WaitAsync(ct).ConfigureAwait(false);
        using var source = CancellationTokenSource.CreateLinkedTokenSource(ct);
        string? callId = null;
        bool prepared = false;
        try
        {
            if (connectedId is not null) throw new InvalidOperationException("本机已有通话，请先结束当前通话。");
            lock (gate) { joining = source; joiningId = null; }
            prepared = true;
            await audio.PrepareAsync(source.Token).ConfigureAwait(false);
            source.Token.ThrowIfCancellationRequested();
            callId = requestedCallId;
            var connection = await request(source.Token).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(connection.Call?.Id)) throw new IOException("服务端未返回有效通话。");
            callId = connection.Call.Id;
            lock (gate) { joiningId = callId; if (ended.Contains(callId)) source.Cancel(); }
            await state.ApplyUpdateAsync(connection.Call!).ConfigureAwait(false);
            if (connection.Call!.Phase == CallPhase.Ended)
            {
                lock (gate) ended.Add(callId);
                throw new IOException("通话已经结束。");
            }
            source.Token.ThrowIfCancellationRequested();
            if (!Uri.TryCreate(connection.Server, UriKind.Absolute, out var server) ||
                !(server.Scheme is "wss" or "https" || (server.IsLoopback && server.Scheme is "ws" or "http")) ||
                server.UserInfo.Length > 0 || string.IsNullOrWhiteSpace(connection.Token) || string.IsNullOrWhiteSpace(connection.Room))
                throw new IOException("服务端未返回有效的音频房间凭据。");
            await audio.JoinAsync(server, connection.Token, connection.Room, source.Token).ConfigureAwait(false);
            source.Token.ThrowIfCancellationRequested();
            connectedId = callId;
            return connection.Call.Clone();
        }
        catch (Exception failure)
        {
            if (prepared)
            {
                var cleanup = await CleanupAsync(callId).ConfigureAwait(false);
                if (cleanup is not null) throw new AggregateException("通话连接失败，收尾尚未完全确认。", failure, cleanup);
            }
            throw;
        }
        finally
        {
            lock (gate) { joining = null; joiningId = null; }
            serial.Release();
        }
    }

    public async Task HangupAsync(string callId, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(callId);
        lock (gate) { if (joiningId == callId) joining?.Cancel(); }
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            try
            {
                var response = await api.HangupCallAsync(new() { CallId = callId }, ct).ConfigureAwait(false);
                if (response.Call is { } call) await state.ApplyUpdateAsync(call).ConfigureAwait(false);
            }
            finally
            {
                if (connectedId == callId)
                {
                    using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    await audio.LeaveAsync(cleanup.Token).ConfigureAwait(false); connectedId = null;
                }
            }
        }
        finally { serial.Release(); }
    }

    public async Task ApplyUpdateAsync(Call update, CancellationToken ct = default)
    {
        var copy = update.Clone();
        if (copy.Phase == CallPhase.Ended)
            lock (gate) { ended.Add(copy.Id); if (joiningId == copy.Id) joining?.Cancel(); }
        await state.ApplyUpdateAsync(copy).ConfigureAwait(false);
        if (copy.Phase != CallPhase.Ended) return;
        await serial.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (connectedId == copy.Id)
            {
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await audio.LeaveAsync(cleanup.Token).ConfigureAwait(false); connectedId = null;
            }
        }
        finally { serial.Release(); }
    }

    private async Task<Exception?> CleanupAsync(string? callId)
    {
        var errors = new List<Exception>();
        bool needsHangup;
        lock (gate) needsHangup = callId is not null && !ended.Contains(callId);
        if (needsHangup)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var response = await api.HangupCallAsync(new() { CallId = callId! }, timeout.Token).ConfigureAwait(false);
                if (response.Call is { } call) await state.ApplyUpdateAsync(call).ConfigureAwait(false);
            }
            catch (Exception error) { errors.Add(error); }
        }
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await audio.LeaveAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (Exception error) { errors.Add(error); }
        return errors.Count == 0 ? null : new AggregateException(errors);
    }

    // 凭据只在编排内部传给音频适配器，不作为 ViewModel 结果或日志内容。
    private sealed class Connection(Call? call, string server, string token, string room)
    {
        public Call? Call { get; } = call;
        public string Server { get; } = server;
        public string Token { get; } = token;
        public string Room { get; } = room;
    }
}
