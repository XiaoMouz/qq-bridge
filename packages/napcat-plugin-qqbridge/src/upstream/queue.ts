// 上游事件的本地持久队列（docs/design.md 4.3）：服务端不在线时事件先落盘，连上后按游标续传。
//
//   <dir>/queue.json            { id, acked }：队列 id（换了数据目录就是新队列，游标从 1 重新开始）与服务端已确认的游标
//   <dir>/seg-<首个游标>.jsonl   每行一个事件 {"c":游标,"at":毫秒,"e":事件}
//
// 只追加写，不做 fsync：断电时最多丢最后几条，服务端重连对账（按 seq 补历史）会把消息补回来。
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

export interface QueuedEvent {
  c: number;
  at: number;
  e: unknown;
}

export interface QueueOptions {
  /** 单个分段文件的大小上限，超过就开新分段。 */
  segmentBytes?: number;
  /** 队列总大小上限：服务端长时间不在线时丢弃最旧的分段（会在服务端表现为游标空洞）。 */
  maxBytes?: number;
  /** 内存里保留最近多少条，追上进度后直接从内存发送。 */
  memoryTail?: number;
  onDrop?: (info: { from: number; to: number; bytes: number }) => void;
}

interface Segment {
  first: number;
  file: string;
  bytes: number;
}

const SEGMENT_RE = /^seg-(\d{16})\.jsonl$/;

export class UpstreamQueue {
  private queueId: string;
  private ackedCursor: number;
  private lastCursor = 0;
  private segments: Segment[] = [];
  private fd: number | null = null;
  private tail: QueuedEvent[] = [];
  private readCache: { file: string; events: QueuedEvent[] } | null = null;
  private readonly segmentBytes: number;
  private readonly maxBytes: number;
  private readonly memoryTail: number;

  private constructor(
    private readonly dir: string,
    meta: { id: string; acked: number },
    private readonly opts: QueueOptions,
  ) {
    this.queueId = meta.id;
    this.ackedCursor = meta.acked;
    this.segmentBytes = opts.segmentBytes ?? 8 * 1024 * 1024;
    this.maxBytes = opts.maxBytes ?? 1024 * 1024 * 1024;
    this.memoryTail = opts.memoryTail ?? 2000;
  }

  static open(dir: string, opts: QueueOptions = {}): UpstreamQueue {
    fs.mkdirSync(dir, { recursive: true });
    const metaFile = path.join(dir, 'queue.json');
    let meta: { id: string; acked: number };
    try {
      const parsed = JSON.parse(fs.readFileSync(metaFile, 'utf8')) as { id?: unknown; acked?: unknown };
      if (typeof parsed.id !== 'string' || typeof parsed.acked !== 'number') throw new Error('bad queue.json');
      meta = { id: parsed.id, acked: parsed.acked };
    } catch {
      meta = { id: randomUUID(), acked: 0 };
    }
    const queue = new UpstreamQueue(dir, meta, opts);
    queue.persistMeta();
    queue.load();
    return queue;
  }

  get id(): string {
    return this.queueId;
  }

  /** 最早还在本地的游标；队列为空时为 last + 1。 */
  get first(): number {
    const firstSegment = this.segments[0];
    return firstSegment ? Math.max(firstSegment.first, 1) : this.lastCursor + 1;
  }

  get last(): number {
    return this.lastCursor;
  }

  get acked(): number {
    return this.ackedCursor;
  }

  get bytes(): number {
    return this.segments.reduce((sum, s) => sum + s.bytes, 0);
  }

  append(event: unknown, at = Date.now()): QueuedEvent {
    const item: QueuedEvent = { c: this.lastCursor + 1, at, e: event };
    const line = JSON.stringify(item) + '\n';
    let current = this.segments[this.segments.length - 1];
    if (!current || this.fd === null || current.bytes >= this.segmentBytes) current = this.rotate(item.c);
    fs.writeSync(this.fd!, line);
    current.bytes += Buffer.byteLength(line);
    this.lastCursor = item.c;
    this.tail.push(item);
    if (this.tail.length > this.memoryTail) this.tail.splice(0, this.tail.length - this.memoryTail);
    return item;
  }

  /** 读取游标大于 after 的事件，最多 limit 条。 */
  read(after: number, limit: number): QueuedEvent[] {
    if (after >= this.lastCursor || limit <= 0) return [];
    const from = Math.max(after + 1, this.first);
    const tailStart = this.tail[0]?.c;
    if (tailStart !== undefined && from >= tailStart) {
      const start = from - tailStart;
      return this.tail.slice(start, start + limit);
    }
    const out: QueuedEvent[] = [];
    for (let i = 0; i < this.segments.length && out.length < limit; i++) {
      const segment = this.segments[i]!;
      const next = this.segments[i + 1];
      if (next && next.first <= from) continue; // 整段都在 from 之前
      for (const event of this.segmentEvents(segment)) {
        if (event.c < from) continue;
        out.push(event);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /** 服务端确认已持久保存到 cursor：删除完全在它之前的分段。 */
  ack(cursor: number): void {
    if (cursor <= this.ackedCursor) return;
    this.ackedCursor = Math.min(cursor, this.lastCursor);
    this.persistMeta();
    while (this.segments.length > 1 && this.segments[1]!.first - 1 <= this.ackedCursor) {
      this.removeSegment(this.segments[0]!);
    }
  }

  /**
   * 换一个新的队列 id（服务端视为全新队列，从本地最早的事件重新接收）。
   * 用于服务端记录的进度比本地还新的情况（例如插件数据目录被还原）：重复的事件服务端会去重，不会丢。
   */
  reset(): void {
    this.queueId = randomUUID();
    this.ackedCursor = 0;
    this.persistMeta();
  }

  close(): void {
    if (this.fd !== null) fs.closeSync(this.fd);
    this.fd = null;
  }

  private load(): void {
    const files = fs
      .readdirSync(this.dir)
      .filter((f) => SEGMENT_RE.test(f))
      .sort();
    for (const file of files) {
      const first = Number(SEGMENT_RE.exec(file)![1]);
      const full = path.join(this.dir, file);
      this.segments.push({ first, file: full, bytes: fs.statSync(full).size });
    }
    const last = this.segments[this.segments.length - 1];
    if (!last) {
      this.lastCursor = this.ackedCursor;
      return;
    }
    // 上次可能在写一行的中途退出：截掉不完整的最后一行。
    const content = fs.readFileSync(last.file);
    const end = content.lastIndexOf(0x0a) + 1;
    if (end < content.length) {
      fs.truncateSync(last.file, end);
      last.bytes = end;
    }
    const events = this.parse(content.subarray(0, end));
    this.lastCursor = events.length > 0 ? events[events.length - 1]!.c : Math.max(last.first - 1, this.ackedCursor);
    this.tail = events.slice(-this.memoryTail);
    this.fd = fs.openSync(last.file, 'a');
  }

  private rotate(firstCursor: number): Segment {
    if (this.fd !== null) fs.closeSync(this.fd);
    const file = path.join(this.dir, `seg-${String(firstCursor).padStart(16, '0')}.jsonl`);
    this.fd = fs.openSync(file, 'a');
    const segment: Segment = { first: firstCursor, file, bytes: 0 };
    this.segments.push(segment);
    // 已确认的旧分段在 ack 时就删了；这里处理服务端长时间不在线、队列超过上限的情况。
    let total = this.bytes;
    while (this.segments.length > 1 && total > this.maxBytes) {
      const oldest = this.segments[0]!;
      const to = this.segments[1]!.first - 1;
      this.opts.onDrop?.({ from: oldest.first, to, bytes: oldest.bytes });
      total -= oldest.bytes;
      this.removeSegment(oldest);
    }
    return segment;
  }

  private removeSegment(segment: Segment): void {
    fs.rmSync(segment.file, { force: true });
    this.segments.splice(this.segments.indexOf(segment), 1);
    if (this.readCache?.file === segment.file) this.readCache = null;
  }

  private segmentEvents(segment: Segment): QueuedEvent[] {
    const isActive = segment === this.segments[this.segments.length - 1];
    if (!isActive && this.readCache?.file === segment.file) return this.readCache.events;
    const events = this.parse(fs.readFileSync(segment.file));
    if (!isActive) this.readCache = { file: segment.file, events };
    return events;
  }

  private parse(content: Buffer): QueuedEvent[] {
    const events: QueuedEvent[] = [];
    for (const line of content.toString('utf8').split('\n')) {
      if (!line) continue;
      try {
        events.push(JSON.parse(line) as QueuedEvent);
      } catch {
        // 损坏的行跳过（只可能出现在异常退出时的最后一行，load 时已截掉）
      }
    }
    return events;
  }

  private persistMeta(): void {
    const file = path.join(this.dir, 'queue.json');
    const tmp = `${file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify({ id: this.id, acked: this.ackedCursor }));
    fs.renameSync(tmp, file);
  }
}
