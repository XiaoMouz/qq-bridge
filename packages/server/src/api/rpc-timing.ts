// RPC 耗时统计：每个方法保留最近一段时间的样本，定时打一行汇总；单次超过阈值的立即记一条。
// 2026-10-24：用户反馈会话、媒体加载慢，原来只统计了上游入库延迟，客户端请求花在哪里看不到。
import type { Interceptor } from '@connectrpc/connect';
import type { Logger } from 'pino';

export interface RpcTimingSummary {
  [method: string]: { count: number; p50: number; p95: number; max: number };
}

export interface PoolStats {
  total: number;
  idle: number;
  waiting: number;
}

export class RpcTiming {
  private samples = new Map<string, number[]>();

  constructor(
    private readonly logger: Logger,
    private readonly slowMs = 1000,
    /** 数据库连接池状态：慢请求时一起记下，判断是不是在排队等连接（2026-10-24 启动后 GetStatus 27 秒，库里查不到慢查询）。 */
    readonly poolStats: () => PoolStats | null = () => null,
  ) {}

  interceptor(): Interceptor {
    return (next) => async (req) => {
      // 订阅流一直开着，耗时没有意义。
      if (req.stream) return next(req);
      const started = performance.now();
      const method = req.method.name;
      try {
        return await next(req);
      } finally {
        const ms = Math.round(performance.now() - started);
        let list = this.samples.get(method);
        if (!list) this.samples.set(method, (list = []));
        list.push(ms);
        if (ms >= this.slowMs) this.logger.warn({ method, ms, pool: this.poolStats() }, 'slow rpc');
      }
    };
  }

  /** 取出上次以来的汇总并清空（没有调用的方法不出现）。 */
  drain(): RpcTimingSummary {
    const out: RpcTimingSummary = {};
    for (const [method, list] of this.samples) {
      const sorted = list.sort((a, b) => a - b);
      const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0;
      out[method] = { count: sorted.length, p50: at(0.5), p95: at(0.95), max: sorted[sorted.length - 1] ?? 0 };
    }
    this.samples = new Map();
    return out;
  }
}
