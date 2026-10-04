// Subscribe(from_pts)：先回放差量，再推送实时更新，两段之间不漏不重（docs/design.md 4.7）。
// 顺序：先挂总线监听（缓冲）→ 再在快照里算差量 → 丢弃缓冲里已被差量覆盖的更新 → 转入实时推送。
import type { Db } from '../db/client.ts';
import type { UpdateBus } from './bus.ts';
import { getDifference, type Difference } from './difference.ts';
import type { Update } from './rows.ts';

export type StreamEvent =
  | { kind: 'difference'; difference: Difference }
  | { kind: 'update'; update: Update }
  | { kind: 'heartbeat'; pts: number }
  /** 客户端跟不上（缓冲溢出）：应断开后用 getDifference 重新追平。 */
  | { kind: 'resync' };

export interface SubscribeOptions {
  pageSize?: number;
  heartbeatMs?: number;
  maxBuffered?: number;
}

export async function* subscribe(
  db: Db,
  bus: UpdateBus,
  accountId: number,
  fromPts: number,
  signal: AbortSignal,
  opts: SubscribeOptions = {},
): AsyncGenerator<StreamEvent> {
  const pageSize = opts.pageSize ?? 500;
  const heartbeatMs = opts.heartbeatMs ?? 25_000;
  const maxBuffered = opts.maxBuffered ?? 10_000;

  const buffer: Update[] = [];
  let overflow = false;
  let wake: (() => void) | null = null;
  const unsubscribe = bus.subscribe(accountId, (update) => {
    if (buffer.length >= maxBuffered) overflow = true;
    else buffer.push(update);
    wake?.();
  });

  try {
    let cursor = fromPts;
    for (;;) {
      const difference = await getDifference(db, accountId, cursor, pageSize);
      yield { kind: 'difference', difference };
      cursor = difference.pts;
      if (difference.final || difference.tooLong) break;
    }

    while (!signal.aborted) {
      if (overflow) {
        yield { kind: 'resync' };
        return;
      }
      while (buffer.length > 0) {
        const update = buffer.shift()!;
        if ('pts' in update) {
          // 已经包含在差量里的（提交于快照之前）跳过；会话内的消息 / 服务事件由客户端按 chat_pts 自行去重，临时事件不占序号。
          if (update.pts <= cursor) continue;
          cursor = update.pts;
        }
        yield { kind: 'update', update };
      }
      const timedOut = await waitFor(heartbeatMs, signal, (resolve) => (wake = resolve));
      wake = null;
      if (timedOut && !signal.aborted && buffer.length === 0) yield { kind: 'heartbeat', pts: cursor };
    }
  } finally {
    unsubscribe();
  }
}

/** 等到被唤醒、超时或取消；超时返回 true。 */
function waitFor(ms: number, signal: AbortSignal, register: (resolve: () => void) => void): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => done(true), ms);
    const onAbort = () => done(false);
    function done(timedOut: boolean) {
      clearTimeout(timer);
      signal.removeEventListener('abort', onAbort);
      resolve(timedOut);
    }
    signal.addEventListener('abort', onAbort, { once: true });
    register(() => done(false));
  });
}
