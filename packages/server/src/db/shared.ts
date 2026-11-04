// 重的统计查询：同样的请求同时只跑一份（后来的共用前一份的结果），可选缓存，每条查询带超时。
// 2026-11-04 实测：存储页同一分钟里 6 个 GetStorageOverview 各跑了一份分类统计（5–34 秒），
// 再加一条 289 秒的全表扫描，把数据库拖到连 commit 都要几秒。
import { sql } from 'drizzle-orm';
import type { Db, Tx } from './client.ts';

/** 存储统计的兜底超时：数据再翻倍也只是这一页加载失败，不拖住整个库。 */
export const STATS_TIMEOUT_MS = 120_000;

/** 在事务里设 statement_timeout 再查（set local 只对这个事务有效，不影响连接池里的其他查询）。 */
export function withStatementTimeout<T>(db: Db, ms: number, fn: (tx: Tx) => Promise<T>): Promise<T> {
  return db.transaction(async (tx) => {
    await tx.execute(sql.raw(`set local statement_timeout = ${Math.max(1, Math.floor(ms))}`));
    return fn(tx);
  });
}

export class SharedResults {
  private running = new Map<string, Promise<unknown>>();
  private cache = new Map<string, { at: number; value: unknown }>();

  /**
   * 同一 key 正在算时直接等那一份；ttlMs > 0 时结果缓存这么久。
   * stale = true：缓存过期后先返回旧值、后台重算（重算同样只跑一份）。
   */
  run<T>(key: string, fn: () => Promise<T>, opts: { ttlMs?: number; stale?: boolean } = {}): Promise<T> {
    const ttl = opts.ttlMs ?? 0;
    const cached = this.cache.get(key);
    if (cached && ttl > 0) {
      if (Date.now() - cached.at < ttl) return Promise.resolve(cached.value as T);
      if (opts.stale) {
        void this.start(key, fn, ttl).catch(() => undefined);
        return Promise.resolve(cached.value as T);
      }
    }
    return this.start(key, fn, ttl);
  }

  /** 等所有正在跑的算完（测试用，也可在关机前调用）。 */
  async idle(): Promise<void> {
    await Promise.allSettled([...this.running.values()]);
  }

  /** 内容变了（例如清理了媒体）：丢掉缓存，下次重算。正在跑的那份不打断。 */
  invalidate(prefix = ''): void {
    for (const key of [...this.cache.keys()]) if (key.startsWith(prefix)) this.cache.delete(key);
  }

  private start<T>(key: string, fn: () => Promise<T>, ttl: number): Promise<T> {
    const running = this.running.get(key);
    if (running) return running as Promise<T>;
    const task = (async () => {
      const value = await fn();
      if (ttl > 0) this.cache.set(key, { at: Date.now(), value });
      return value;
    })().finally(() => this.running.delete(key));
    this.running.set(key, task);
    return task;
  }
}
