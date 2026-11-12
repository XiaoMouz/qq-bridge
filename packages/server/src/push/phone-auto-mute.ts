// 「本机在线时自动停用通知到手机」（Mac 设置）：开着这个选项的设备每 30 秒 ReportPresence(mute_phone = true)，
// 租约 75 秒；只要有一台设备的租约有效，账号的 phone_auto_off 就是 true，新消息不推 iOS 设备。
// 不用 Subscribe 连接判断在线：Mac 合盖睡眠时，服务端那头的连接要等 TCP 重传超时（几分钟）才断，期间手机一直收不到通知。
// 手机上点「打开」（SetAccountSettings.override_auto_off）：把当前在线的这些设备记为「已解除」，它们下线前不再算；
// 下线（租约过期或报 false）后清掉，下次上线重新生效。
// 租约和「已解除」都只在内存：服务端重启时把库里的 phone_auto_off 清零，设备 30 秒内重新报到后恢复。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { rows, type Db } from '../db/client.ts';
import { setPhoneAutoOff } from '../auth/settings.ts';
import type { WriterRegistry } from '../sync/writer.ts';

export const PRESENCE_LEASE_MS = 75_000;

interface AccountState {
  /** deviceId → 租约到期时间。 */
  leases: Map<number, number>;
  /** 手机上点了「打开」时在线的设备：下线前不算。 */
  overridden: Set<number>;
}

export class PhoneAutoMute {
  private readonly accounts = new Map<number, AccountState>();
  private timer: ReturnType<typeof setInterval> | null = null;
  /** 同一账号的重算串行执行，避免两次写库交错。 */
  private readonly chains = new Map<number, Promise<void>>();

  constructor(
    private readonly db: Db,
    private readonly writers: WriterRegistry,
    private readonly opts: { logger?: Logger; now?: () => number; leaseMs?: number } = {},
  ) {}

  private now(): number {
    return this.opts.now?.() ?? Date.now();
  }

  private state(accountId: number): AccountState {
    let s = this.accounts.get(accountId);
    if (!s) {
      s = { leases: new Map(), overridden: new Set() };
      this.accounts.set(accountId, s);
    }
    return s;
  }

  /** 启动：清掉上次运行留下的自动停用（租约已丢），并开始定时检查过期。 */
  async start(intervalMs = 10_000): Promise<void> {
    const stale = await rows<{ id: number }>(this.db, sql`select id from accounts where phone_auto_off`);
    for (const { id } of stale) await setPhoneAutoOff(this.writers, id, false);
    this.timer = setInterval(() => void this.expire(), intervalMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  async report(accountId: number, deviceId: number, mute: boolean): Promise<void> {
    const s = this.state(accountId);
    if (mute) {
      const wasOnline = s.leases.has(deviceId);
      s.leases.set(deviceId, this.now() + (this.opts.leaseMs ?? PRESENCE_LEASE_MS));
      if (!wasOnline) this.opts.logger?.info({ accountId, deviceId }, 'device online, auto mute phone');
    } else if (s.leases.delete(deviceId)) {
      s.overridden.delete(deviceId);
      this.opts.logger?.info({ accountId, deviceId }, 'device stopped auto muting phone');
    }
    await this.recompute(accountId);
  }

  /** 手机上点了「打开」：当前在线的设备在下线前不再暂停手机通知。 */
  async override(accountId: number): Promise<void> {
    const s = this.state(accountId);
    for (const id of s.leases.keys()) s.overridden.add(id);
    await this.recompute(accountId);
  }

  /** 过期的租约当作下线。 */
  async expire(): Promise<void> {
    const now = this.now();
    for (const [accountId, s] of this.accounts) {
      let changed = false;
      for (const [deviceId, until] of s.leases) {
        if (until > now) continue;
        s.leases.delete(deviceId);
        s.overridden.delete(deviceId);
        changed = true;
        this.opts.logger?.info({ accountId, deviceId }, 'device presence expired, resume phone notifications');
      }
      if (changed) await this.recompute(accountId);
    }
  }

  isActive(accountId: number): boolean {
    const s = this.accounts.get(accountId);
    if (!s) return false;
    for (const id of s.leases.keys()) if (!s.overridden.has(id)) return true;
    return false;
  }

  private recompute(accountId: number): Promise<void> {
    const prev = this.chains.get(accountId) ?? Promise.resolve();
    const next = prev
      .then(async () => {
        const saved = await setPhoneAutoOff(this.writers, accountId, this.isActive(accountId));
        if (saved) this.opts.logger?.info({ accountId, phoneAutoOff: saved.phoneAutoOff }, 'phone auto off changed');
      })
      .catch((error: unknown) => this.opts.logger?.warn({ err: error, accountId }, 'phone auto off update failed'));
    this.chains.set(accountId, next);
    return next;
  }
}
