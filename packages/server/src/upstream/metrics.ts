// 实时链路延迟统计（docs/design.md 4.7"可观测"）：保留最近 N 条样本，按需算分位数。
//   transport = 服务端收到 − 插件入队（插件队列 + WebSocket；容器和宿主机共用时钟）
//   ingest    = 入库完成 − 服务端收到（收件箱 → 映射 → 单写者事务提交 → 发布）
export interface LatencySample {
  transportMs: number;
  ingestMs: number;
}

export interface LatencySummary {
  count: number;
  transport: { p50: number; p95: number; max: number };
  ingest: { p50: number; p95: number; max: number };
}

export class LatencyStats {
  private readonly samples: LatencySample[] = [];
  private total = 0;

  constructor(private readonly capacity = 1000) {}

  record(sample: LatencySample): void {
    this.samples.push(sample);
    if (this.samples.length > this.capacity) this.samples.shift();
    this.total += 1;
  }

  /** 累计记录过的样本数（用于判断有没有新数据）。 */
  get recorded(): number {
    return this.total;
  }

  summary(): LatencySummary {
    const pick = (key: keyof LatencySample) => {
      const sorted = this.samples.map((s) => s[key]).sort((a, b) => a - b);
      const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] ?? 0;
      return { p50: at(0.5), p95: at(0.95), max: sorted[sorted.length - 1] ?? 0 };
    };
    return { count: this.samples.length, transport: pick('transportMs'), ingest: pick('ingestMs') };
  }
}
