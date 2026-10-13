// 现在连着 Subscribe 流的设备（App 在前台时才连；进后台就断开）。
// 来电时据此决定：连着的设备由 App 内的来电界面处理，没连着的发 VoIP 推送交给 CallKit。
export class OnlineDevices {
  private readonly streams = new Map<number, number>();

  add(deviceId: number): void {
    this.streams.set(deviceId, (this.streams.get(deviceId) ?? 0) + 1);
  }

  remove(deviceId: number): void {
    const n = (this.streams.get(deviceId) ?? 0) - 1;
    if (n > 0) this.streams.set(deviceId, n);
    else this.streams.delete(deviceId);
  }

  has(deviceId: number): boolean {
    return (this.streams.get(deviceId) ?? 0) > 0;
  }
}
