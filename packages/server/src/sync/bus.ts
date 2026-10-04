import type { Update } from './rows.ts';

export type UpdateListener = (update: Update) => void;

/**
 * 进程内的更新总线：写事务提交之后才发布，订阅流据此推送给在线客户端。
 * 同一账号的写入经过单写者串行化，所以发布顺序与提交顺序一致。
 */
export class UpdateBus {
  private readonly listeners = new Map<number, Set<UpdateListener>>();

  subscribe(accountId: number, listener: UpdateListener): () => void {
    let set = this.listeners.get(accountId);
    if (!set) this.listeners.set(accountId, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0) this.listeners.delete(accountId);
    };
  }

  publish(accountId: number, update: Update): void {
    const set = this.listeners.get(accountId);
    if (!set) return;
    for (const listener of [...set]) {
      try {
        listener(update);
      } catch {
        // 单个订阅者出错不能影响其他订阅者，也不能影响写入方。
      }
    }
  }

  listenerCount(accountId: number): number {
    return this.listeners.get(accountId)?.size ?? 0;
  }
}
