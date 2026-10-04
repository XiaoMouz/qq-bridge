// 各设备"正在看哪个会话"（DialogService.SetActiveChat）。只存在内存里，过期自动失效：
// 客户端停留期间每分钟刷新一次，App 被挂起后不再刷新，2 分钟后自然消失。
// 用途：媒体下载优先处理正在看的会话（docs/design.md 4.7"当前会话的实时性"）。
export const ACTIVE_CHAT_TTL_MS = 120_000;

export class ActiveChats {
  private readonly byDevice = new Map<number, { chatId: number; expiresAt: number }>();

  constructor(
    private readonly ttlMs = ACTIVE_CHAT_TTL_MS,
    private readonly now: () => number = Date.now,
  ) {}

  /** chatId 为 null 表示这台设备退出了会话。 */
  set(deviceId: number, chatId: number | null): void {
    if (chatId === null) this.byDevice.delete(deviceId);
    else this.byDevice.set(deviceId, { chatId, expiresAt: this.now() + this.ttlMs });
  }

  /** 当前所有设备正在看的会话（去重）。 */
  chatIds(): number[] {
    const now = this.now();
    const ids = new Set<number>();
    for (const [deviceId, entry] of this.byDevice) {
      if (entry.expiresAt <= now) this.byDevice.delete(deviceId);
      else ids.add(entry.chatId);
    }
    return [...ids];
  }
}
