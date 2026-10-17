using System.ComponentModel;
using Qqbridge.V1;

namespace BetterChat.Application.ViewModels;

public sealed class DevicesViewModel : INotifyPropertyChanged, IDisposable, IAsyncDisposable
{
    private readonly HashSet<long> revoked = [];
    private readonly object gate = new();
    private List<Device> devices = [];
    private bool disposed;
    public IReadOnlyList<Device> Items { get { lock (gate) return devices.Where(d => !revoked.Contains(d.Id)).Select(d => d.Clone()).ToArray(); } }
    public RpcOperationViewModel<ListDevicesRequest, ListDevicesResponse> Load { get; }
    public RpcOperationViewModel<RevokeDeviceRequest, RevokeDeviceResponse> Revoke { get; }
    public event PropertyChangedEventHandler? PropertyChanged;

    public DevicesViewModel(Func<ListDevicesRequest, CancellationToken, Task<ListDevicesResponse>> load,
        Func<RevokeDeviceRequest, CancellationToken, Task<RevokeDeviceResponse>> revoke, IUiDispatcher dispatcher)
    {
        Load = new(async (request, ct) =>
        {
            var response = await load(new(), ct).ConfigureAwait(false);
            if (response.Devices.Any(d => d.Id <= 0) || response.Devices.Select(d => d.Id).Distinct().Count() != response.Devices.Count)
                throw new IOException("设备列表包含无效或重复标识。");
            await dispatcher.InvokeAsync(() =>
            {
                ct.ThrowIfCancellationRequested();
                lock (gate) { if (disposed) return; devices = response.Devices.Select(d => d.Clone()).ToList(); }
                PropertyChanged?.Invoke(this, new(nameof(Items)));
            }).ConfigureAwait(false);
            return response;
        }, dispatcher, false);
        Revoke = new(async (request, ct) =>
        {
            long id = request.DeviceId;
            lock (gate)
            {
                if (disposed || id <= 0 || id > 9007199254740991 || revoked.Contains(id)
                    || !devices.Any(d => d.Id == id && !d.Current))
                    throw new InvalidOperationException("请选择已加载的其他设备；当前设备请使用退出登录。");
            }
            var response = await revoke(new() { DeviceId = id }, ct).ConfigureAwait(false);
            // revoked=false 表示已不再有可撤销记录，也视为该设备不在有效列表；迟到列表不能把它放回去。
            lock (gate) revoked.Add(id);
            await dispatcher.InvokeAsync(() => { lock (gate) { if (disposed) return; } PropertyChanged?.Invoke(this, new(nameof(Items))); }).ConfigureAwait(false);
            return response;
        }, dispatcher, true);
    }
    public Task<bool> LoadAsync(CancellationToken ct = default) => Load.ExecuteAsync(new(), ct);
    public Task<bool> RevokeAsync(long id, CancellationToken ct = default) => Revoke.ExecuteAsync(new() { DeviceId = id }, ct);
    public void Dispose() { lock (gate) disposed = true; Load.Dispose(); Revoke.Dispose(); }
    public async ValueTask DisposeAsync() { Dispose(); await Task.WhenAll(Load.WaitForIdleAsync(), Revoke.WaitForIdleAsync()).ConfigureAwait(false); }
}
