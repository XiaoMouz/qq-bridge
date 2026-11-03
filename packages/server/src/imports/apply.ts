// 备份导入（写入生产）：importer.py 按会话读出备份消息 → 和现有库逐条比对 → 只写生产没有的。
// 存法和实时消息相同：NT 原始消息交给 mapRawMessage，消息经 IngestService.importMessages（内部与 ingestMessage 共用 insertMessage）。
//
// 2026-11-04 实测依据（见 docs/changelog.md 同日条目）：
// - 字段对应由 18020 条「备份与生产为同一条」的消息推导；转换后经 mapRawMessage 映射，98.6% 与生产存的消息段完全一致，
//   其余为生产保留了撤回原文、备份缺贴图摘要等已知差异。
// - 去重：重叠两周里 18038 条真消息全部认出是生产已有的；同一秒连发的 87 组各自对上不同的那条。
// - 同 seq 的 20.5 万组几乎都是手机本地插入、借用旁边消息 seq 的灰条 / 通话记录 / 发送失败的消息；
//   真消息同 seq 只有私聊 200 条（seq 0、私聊 seq 重新编号），给替代 seq（见 syntheticSeq）。
// - 版本：比生产最早一条还旧的老历史 version 0，不进增量同步；落在生产已有范围里的补洞照常分配 chat_pts（见 IngestService.importMessages）。
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import type { IncomingMedia, IncomingMessage, Scene, Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import { stripNul } from '../db/nul.ts';
import { resolveTipPeople, type ForwardNodeInput, type IngestService } from '../ingest/service.ts';
import { findBlobBySha256, type ReusableBlob } from '../media/accounting.ts';
import type { MediaProcessor } from '../media/processing.ts';
import type { MediaService } from '../media/service.ts';
import { grayTipSegments } from '../upstream/napcat/gray-tip.ts';
import { mapRawMessage } from '../upstream/napcat/map.ts';
import type { NtElement, NtRawMessage } from '../upstream/napcat/types.ts';
import { BackupMatcher, type BackupRecord } from './matcher.ts';
import { ReaderProcess } from './process.ts';

type SourceKey = [string, number, string, string];
interface MediaLink { status: string; sha256: string | null }
interface Tip {
  type: number;
  kind: string;
  grayTip?: Record<string, any> | null;
  savedText?: string | null;
  interaction?: Record<string, string> | null;
  dynamic?: { relatedUins?: string[]; descriptions?: { text?: string }[] } | null;
  recalled: NtElement[];
}
export interface ExportRecord {
  sourceKey: SourceKey;
  kind: 'message' | 'tip' | 'call' | 'unsent' | 'unparsed';
  scene: Scene | null;
  sendStatus: number | null;
  nt: NtRawMessage & { elements: NtElement[] };
  media: Record<string, MediaLink>;
  record: BackupRecord;
  tips?: Tip[];
  forward?: { path: string; nodes: { sourcePath: number[]; nt: NtRawMessage & { elements: NtElement[] } }[] }[];
  reason?: string;
}
interface Batch { table: string | null; records: ExportRecord[]; cursor: [number, number, number] | null; tableDone: boolean; finished?: boolean }
interface ChatContext { scene: Scene; peerId: number; existedAtStart: boolean; floorSeq: number | null; floorTime: number | null }

export interface ApplyOptions {
  backupPath: string;
  keysPath: string;
  scanPath: string;
  statePath: string;
  reportPath: string;
  stagingDir: string;
  qqAccountId: number;
  tables?: string[];
  /** 只统计不写库、不拷媒体。 */
  dryRun: boolean;
  batchSize?: number;
  /** 最多处理多少批（试跑用）；不填跑完。 */
  maxBatches?: number;
  onProgress?: (summary: Record<string, number>, table: string | null) => void;
}

/** 生产里这些结论都说明是同一条消息：保留生产的，不覆盖。 */
const DUPLICATE = new Set(['same', 'same_identity_content_variant', 'same_identity_time_variant', 'same_identity_preserve_recalled']);
/**
 * 几个导入进程并行时，同一份热门表情在不同会话里被引用，blobs 的引用计数行加锁顺序不同会死锁
 * （2026-11-04 实测 chat_storage / blobs 上 deadlock detected）。被选为牺牲方的事务整体回滚，等一下重做即可。
 */
async function retrying<T>(fn: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (error) {
      const code = (error as { code?: string; cause?: { code?: string } }).cause?.code ?? (error as { code?: string }).code;
      if (attempt >= 8 || (code !== '40P01' && code !== '40001')) throw error;
      await new Promise((resolve) => setTimeout(resolve, 100 * attempt + Math.random() * 400));
    }
  }
}
/** 每个写事务最多多少条：事务越长，引用计数行锁得越久，实时入库要等越久。 */
const WRITE_CHUNK = 50;
/** 新建会话放进增量同步的条数（客户端首屏）；更早的翻页时取。 */
const NEW_CHAT_FIRST_PAGE = 50;
/**
 * 替代 seq：私聊 seq 为 0 或重新编号后撞号的真消息（2026-11-04 全备份只有 200 条）。取负数区间、按时间排序，
 * 排在会话所有正常 seq 之前；原始 seq 留在 raw.backupSource。
 */
const SYNTHETIC_BASE = -(2 ** 52);
const syntheticSeq = (time: number, k: number) => SYNTHETIC_BASE + time * 1024 + k;

/**
 * 映射器给每个媒体的 ord 对应哪个元素：图片、语音、视频、文件各一个；商城表情只在 emojiId 是 32 位十六进制时有（见 map.ts 的 MFACE）。
 * 按元素顺序数出来，和 mapRawMessage 的 ord 分配一致（市场表情的媒体没有定位信息，不能靠 locator.elementId）。
 */
function mediaElements(elements: NtElement[]): number[] {
  const out: number[] = [];
  elements.forEach((e, i) => {
    if ([2, 3, 4, 5].includes(e.elementType)) out.push(i);
    else if (e.elementType === 11 && /^[0-9a-f]{32}$/i.test(e.marketFaceElement?.emojiId ?? '')) out.push(i);
  });
  return out;
}

export class BackupApplier {
  private readonly matcher: BackupMatcher;
  private readonly summary: Record<string, number> = {};
  private readonly uids = new Map<string, number | null>();
  private readonly blobs = new Map<string, ReusableBlob | null>();
  private readonly chats = new Map<string, ChatContext>();
  private reader!: Pick<ReaderProcess, 'request' | 'stop'>;
  private report!: fs.FileHandle;
  private selfUin = 0;
  private qqAccountId = 0;

  constructor(
    private readonly db: Db,
    private readonly ingest: IngestService,
    private readonly media: MediaService,
    private readonly processor: MediaProcessor | null,
    private readonly python: string,
    private readonly native: string,
    private readonly logger: Logger,
    /** 测试注入假的读取端；默认启动 importer.py。 */
    private readonly openReader: () => Pick<ReaderProcess, 'request' | 'stop'> = () => new ReaderProcess(python, native, 'importer.py'),
  ) {
    this.matcher = new BackupMatcher(db);
  }

  private count(key: string, n = 1): void {
    this.summary[key] = (this.summary[key] ?? 0) + n;
  }

  /** 各阶段累计耗时（毫秒），进度里和计数一起输出，方便看慢在哪。 */
  private async timed<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const started = performance.now();
    try { return await fn(); } finally { this.count(`ms_${key}`, Math.round(performance.now() - started)); }
  }

  private async note(record: { sourceKey: SourceKey }, outcome: string, extra: Record<string, unknown> = {}): Promise<void> {
    this.count(outcome);
    await this.report.write(JSON.stringify({ sourceKey: record.sourceKey, outcome, ...extra }) + '\n');
  }

  async run(opts: ApplyOptions): Promise<Record<string, number>> {
    const qq = await maybeOne<{ uin: number }>(this.db, sql`select uin from qq_accounts where id = ${opts.qqAccountId}`);
    if (!qq) throw new Error(`qq account ${opts.qqAccountId} not found`);
    this.selfUin = Number(qq.uin);
    this.qqAccountId = opts.qqAccountId;
    await fs.mkdir(opts.stagingDir, { recursive: true, mode: 0o700 });
    this.report = await fs.open(opts.reportPath, 'a');
    this.reader = this.openReader();
    try {
      await this.reader.request({ command: 'open', config: {
        backupPath: opts.backupPath, keysPath: opts.keysPath, scanPath: opts.scanPath, statePath: opts.statePath, tables: opts.tables ?? [],
      } });
      for (let n = 0; opts.maxBatches === undefined || n < opts.maxBatches; n++) {
        const batch: Batch = await this.timed('read', () => this.reader.request({ command: 'next', limit: opts.batchSize ?? 200 }));
        if (batch.finished || !batch.table) break;
        if (batch.records.length) await this.timed('apply', () => this.apply(batch.table!, batch.records, opts));
        if (batch.tableDone) await this.finishTable(batch.table, opts);
        await this.reader.request({ command: 'commit', table: batch.table, cursor: batch.cursor, tableDone: batch.tableDone });
        opts.onProgress?.(this.summary, batch.table);
      }
    } finally {
      await this.reader.stop();
      await this.report.close();
    }
    return this.summary;
  }

  /**
   * 媒体预取：把预检里唯一对应到文件的内容先拷进媒体库（与导入进程并行，按 sha256 分片）。
   * 导入写消息时 findBlobBySha256 直接命中，不用逐条等解密、落盘、生成派生版本（2026-11-04 实测这是导入最慢的一段）。
   */
  async prefetchMedia(opts: Pick<ApplyOptions, 'backupPath' | 'keysPath' | 'scanPath' | 'statePath' | 'stagingDir' | 'onProgress'> & { shard: number; shards: number }): Promise<Record<string, number>> {
    await fs.mkdir(opts.stagingDir, { recursive: true, mode: 0o700 });
    this.reader = this.openReader();
    const full = { ...opts, reportPath: '', qqAccountId: 0, dryRun: false } as ApplyOptions;
    try {
      await this.reader.request({ command: 'open', config: { backupPath: opts.backupPath, keysPath: opts.keysPath, scanPath: opts.scanPath, statePath: opts.statePath, tables: [] } });
      let after: string | null = '';
      while (after !== null) {
        const page: { items: { sha256: string; mime: string | null }[]; after: string | null } =
          await this.reader.request({ command: 'media_list', shard: opts.shard, shards: opts.shards, after, limit: 500 });
        for (const item of page.items) {
          const mime = item.mime ?? '';
          const kind = mime.startsWith('image/') ? 'image' : mime.startsWith('audio/') ? 'audio' : mime.startsWith('video/') ? 'video' : 'file';
          await this.ensureBlob(item.sha256, kind, full);
        }
        after = page.after;
        opts.onProgress?.(this.summary, after);
      }
    } finally {
      await this.reader.stop();
    }
    return this.summary;
  }

  /** 会话在导入开始时的状态（第一次碰到时记进导入状态库，续跑时沿用，不受已导入的消息影响）。 */
  private async context(table: string, scene: Scene): Promise<ChatContext> {
    const key = `chat:${table}:${scene}`;
    const cached = this.chats.get(key);
    if (cached) return cached;
    const stored = (await this.reader.request({ command: 'meta_get', key })).value as ChatContext | null;
    if (stored) {
      this.chats.set(key, stored);
      return stored;
    }
    const peerId = Number(table.split('_')[2]);
    const chat = await maybeOne<{ id: number }>(
      this.db,
      sql`select id from chats where qq_account_id = ${this.qqAccountId} and scene = ${scene} and peer_id = ${peerId}`,
    );
    const floor = chat
      ? await maybeOne<{ seq: number | null; time: number | null }>(
          this.db,
          sql`select min(seq) as seq, extract(epoch from min(time))::bigint as time from messages where chat_id = ${chat.id}`,
        )
      : null;
    const ctx: ChatContext = {
      scene, peerId, existedAtStart: Boolean(chat),
      floorSeq: floor?.seq === null || floor?.seq === undefined ? null : Number(floor.seq),
      floorTime: floor?.time === null || floor?.time === undefined ? null : Number(floor.time),
    };
    await this.reader.request({ command: 'meta_set', key, value: ctx });
    this.chats.set(key, ctx);
    return ctx;
  }
  /** 消息该不该进增量同步：新会话先全写 0（表读完再放最新一页进来），老会话里比生产最早一条还旧的写 0。 */
  private versionOf(ctx: ChatContext, seq: number, time: number): number | undefined {
    if (!ctx.existedAtStart) return 0;
    if (seq < 0) return 0;
    if (ctx.floorSeq !== null && seq < ctx.floorSeq) return 0;
    if (ctx.floorSeq === null && ctx.floorTime !== null && time < ctx.floorTime) return 0;
    return undefined;
  }
  private eventVersion(ctx: ChatContext, time: number): number | undefined {
    if (!ctx.existedAtStart) return 0;
    return ctx.floorTime !== null && time < ctx.floorTime ? 0 : undefined;
  }

  private async apply(table: string, input: ExportRecord[], opts: ApplyOptions): Promise<void> {
    // Postgres 的 text / jsonb 存不了 NUL；不只写库，去重、匹配的查询参数也会报错，所以进来就统一去掉。
    // （2026-11-04 群 1062402186 的「本群每分钟只能发5条消息」末尾带 NUL，是灰条 JSON 里的 \u0000，见 applyTips。）
    const records = input.map(stripNul);
    const byScene = new Map<Scene, ExportRecord[]>();
    for (const r of records) {
      if (r.kind === 'unparsed') { await this.note(r, 'unparsed', { reason: r.reason }); continue; }
      if (r.kind === 'unsent') { await this.note(r, 'unsent_local_only'); continue; }
      if (!r.scene) { await this.note(r, 'unsupported_chat_type'); continue; }
      byScene.set(r.scene, [...(byScene.get(r.scene) ?? []), r]);
    }
    for (const [scene, list] of byScene) {
      const ctx = await this.context(table, scene);
      await this.applyMessages(ctx, list.filter((r) => r.kind === 'message'), opts);
      await this.applyTips(ctx, list.filter((r) => r.kind === 'tip' || r.kind === 'call'), opts);
      if (!opts.dryRun) await this.timed('verified', () => this.markVerified(ctx));
    }
  }

  /**
   * 导入覆盖的那段记为已核对：缺口补齐只看 [最早一条, 最新一条]，老历史导进来后最早一条提前了好几年，
   * 备份里本来就没有的 seq 会全变成缺口、让服务端不停向 QQ 要历史。导入前它从不自动追生产最早一条之前的，导入后也不。
   * 每批写完就记（大群要导很久，缺口补齐每 10 分钟一轮，不能等整个会话导完）；往上翻到顶的懒回填、深度归档不受影响。
   */
  private async markVerified(ctx: ChatContext): Promise<void> {
    const chat = await maybeOne<{ id: number; lo: number | null; hi: number | null }>(
      this.db,
      sql`select c.id, (select min(seq) from messages where chat_id = c.id and seq > 0) as lo,
                 (select max(seq) from messages where chat_id = c.id and seq > 0) as hi
            from chats c where c.qq_account_id = ${this.qqAccountId} and c.scene = ${ctx.scene} and c.peer_id = ${ctx.peerId}`,
    );
    if (!chat || chat.lo === null || chat.hi === null) return;
    const upper = ctx.existedAtStart && ctx.floorSeq !== null ? ctx.floorSeq : Number(chat.hi) + 1;
    if (Number(chat.lo) >= upper) return;
    await this.db.execute(
      sql`update chats set verified_ranges = verified_ranges + int8multirange(int8range(${Number(chat.lo)}, ${upper}))
           where id = ${chat.id} and not verified_ranges @> int8range(${Number(chat.lo)}, ${upper})`,
    );
  }

  // ---------- 普通消息 ----------

  private async applyMessages(ctx: ChatContext, records: ExportRecord[], opts: ApplyOptions): Promise<void> {
    if (!records.length) return;
    // 比生产最早一条还旧的、新会话里的：生产不可能有同一条（同一条消息 seq 相同），不必逐条比对。
    const needMatch = records.filter((r) => ctx.existedAtStart && !(ctx.floorSeq !== null && Number(r.nt.msgSeq) > 0 && Number(r.nt.msgSeq) < ctx.floorSeq));
    const matches = new Map<ExportRecord, { status: string; messageId?: string }>();
    if (needMatch.length) {
      const results = await this.timed('match', () => this.matcher.matchBatch(opts.qqAccountId, needMatch.map((r) => r.record)));
      results.forEach((m, i) => matches.set(needMatch[i]!, m));
    }
    const items: Parameters<IngestService['importMessages']>[3][number][] = [];
    const pending: { record: ExportRecord; msg: IncomingMessage }[] = [];
    for (const r of records) {
      const m = matches.get(r);
      if (m && DUPLICATE.has(m.status)) {
        await this.note(r, 'duplicate', { status: m.status });
        if (r.forward && m.messageId) await this.fillForward(ctx, r, Number(r.nt.msgSeq), opts);
        continue;
      }
      if (m?.status === 'ambiguous') { await this.note(r, 'ambiguous_skipped'); continue; }
      const nt = await this.resolveUids(r.nt);
      let seq = Number(nt.msgSeq);
      if (!(seq > 0) || m?.status === 'seq_conflict') {
        // seq 0，或同 seq 已被生产里另一条消息占用（私聊重新编号）：确认占用的确实是别的消息再换替代 seq。
        if (m?.status === 'seq_conflict' && !(await this.occupiedByOther(ctx, seq, r))) { await this.note(r, 'conflict_unverified'); continue; }
        if (await this.reassignedBefore(ctx, r)) { await this.note(r, 'already_imported'); continue; }
        seq = await this.freeSyntheticSeq(ctx, Number(nt.msgTime));
        nt.backupSource = { ...(nt.backupSource as object), seqReassigned: true };
      }
      const msg = this.toIncoming(nt, seq);
      if (!msg) { await this.note(r, 'unmappable'); continue; }
      const known = await this.knownMedia(msg.media, nt.elements, r.media, '', opts);
      items.push({ msg, ...(this.versionOf(ctx, seq, msg.time) === undefined ? {} : { version: 0 }), known });
      pending.push({ record: r, msg });
    }
    if (!items.length) return;
    if (opts.dryRun) {
      for (const p of pending) this.count(this.versionOf(ctx, p.msg.seq, p.msg.time) === 0 ? 'would_insert_history' : 'would_insert_gap');
      return;
    }
    const occupied = new Set<number>();
    for (let i = 0; i < items.length; i += WRITE_CHUNK) {
      const chunk = items.slice(i, i + WRITE_CHUNK);
      const result = await this.timed('write', () => retrying(() => this.ingest.importMessages(opts.qqAccountId, ctx.scene, ctx.peerId, chunk, { readThrough: !ctx.existedAtStart })));
      for (const seq of result.occupied) occupied.add(seq);
    }
    for (const p of pending) {
      if (occupied.has(p.msg.seq)) {
        // 同一批里备份自己就有两条真消息同 seq（或别的写入抢先）：确认不是同一条后换替代 seq 再写。
        if (!(await this.occupiedByOther(ctx, p.msg.seq, p.record)) || (await this.reassignedBefore(ctx, p.record))) {
          // 续跑时上次已写入、游标还没前进的那批：消息已在，合并转发可能还没写（写过的 fillForward 会跳过）。
          await this.note(p.record, 'already_imported');
          if (p.record.forward) await this.fillForward(ctx, p.record, p.msg.seq, opts);
          continue;
        }
        const seq = await this.freeSyntheticSeq(ctx, p.msg.time);
        const raw = p.msg.raw as NtRawMessage;
        const retry = { ...p.msg, seq, raw: { ...raw, backupSource: { ...(raw.backupSource as object), seqReassigned: true } } };
        const known = await this.knownMedia(retry.media, p.record.nt.elements, p.record.media, '', opts);
        await retrying(() => this.ingest.importMessages(opts.qqAccountId, ctx.scene, ctx.peerId, [{ msg: retry, version: 0, known }], { readThrough: !ctx.existedAtStart }));
        await this.note(p.record, 'inserted_reassigned_seq', { seq });
        continue;
      }
      this.count(this.versionOf(ctx, p.msg.seq, p.msg.time) === 0 ? 'inserted_history' : 'inserted_gap');
      if (p.record.forward) await this.fillForward(ctx, p.record, p.msg.seq, opts);
    }
  }

  /** 生产里 (会话, seq) 上的消息是不是另一条（random / 时间对不上）。 */
  private async occupiedByOther(ctx: ChatContext, seq: number, r: ExportRecord): Promise<boolean> {
    const row = await maybeOne<{ random: string | null; time: number }>(
      this.db,
      sql`select m.random::text as random, extract(epoch from m.time)::bigint as time from messages m join chats c on c.id = m.chat_id
           where c.qq_account_id = ${this.qqAccountId} and c.scene = ${ctx.scene} and c.peer_id = ${ctx.peerId} and m.seq = ${seq}`,
    );
    if (!row) return false;
    return row.random !== String(r.nt.msgRandom) || Math.abs(Number(row.time) - Number(r.nt.msgTime)) > 1;
  }

  /** 这条备份消息以前已经用替代 seq 导入过（续跑、重跑时不能再换一个新的替代 seq 重复写）。替代 seq 很少，只查负数区间。 */
  private async reassignedBefore(ctx: ChatContext, r: ExportRecord): Promise<boolean> {
    const [table, time, seq, random] = r.sourceKey;
    const hit = await maybeOne<{ x: number }>(
      this.db,
      sql`select 1 as x from messages m join chats c on c.id = m.chat_id
           where c.qq_account_id = ${this.qqAccountId} and c.scene = ${ctx.scene} and c.peer_id = ${ctx.peerId} and m.seq < 0
             and m.raw->'backupSource'->>'table' = ${table} and m.raw->'backupSource'->>'time' = ${String(time)}
             and m.raw->'backupSource'->>'seq' = ${seq} and m.raw->'backupSource'->>'random' = ${random}
           limit 1`,
    );
    return Boolean(hit);
  }

  private async freeSyntheticSeq(ctx: ChatContext, time: number): Promise<number> {
    const taken = await rows<{ seq: number }>(
      this.db,
      sql`select m.seq from messages m join chats c on c.id = m.chat_id
           where c.qq_account_id = ${this.qqAccountId} and c.scene = ${ctx.scene} and c.peer_id = ${ctx.peerId}
             and m.seq between ${syntheticSeq(time, 0)} and ${syntheticSeq(time, 1023)}`,
    );
    const used = new Set(taken.map((t) => Number(t.seq)));
    for (let k = 0; k < 1024; k++) if (!used.has(syntheticSeq(time, k))) return syntheticSeq(time, k);
    throw new Error(`no synthetic seq left at ${time}`);
  }

  /**
   * NT 原始消息 → 规范化消息（和实时、历史回填同一个映射器）。映射器要求 seq 为正，替代 seq（负数）在映射之后再换上，
   * raw 里仍是备份的原始 seq。
   */
  private toIncoming(nt: NtRawMessage, seq: number): IncomingMessage | null {
    const action = mapRawMessage(Number(nt.msgSeq) > 0 ? nt : { ...nt, msgSeq: '1' }, { selfUin: this.selfUin, source: 'backfill' });
    if (action.type !== 'message') return null;
    return { ...action.message, seq, raw: nt };
  }

  /**
   * 手机备份里回复的作者、@ 的人有时只有 uid 没有号码（2026-11-04 重叠窗口：回复约 64 条、@ 约 177 条）；
   * 按本地资料换成号码，换不到的保持原样（映射器照常把 @ 存成文字）。
   */
  private async resolveUids<T extends NtRawMessage & { elements: NtElement[] }>(nt: T): Promise<T> {
    const elements: NtElement[] = [];
    for (const e of nt.elements) {
      if (e.textElement?.atType === 2 && !e.textElement.atUid && e.textElement.atNtUid) {
        const uin = await this.uinOf(e.textElement.atNtUid);
        elements.push(uin ? { ...e, textElement: { ...e.textElement, atUid: String(uin) } } : e);
      } else if (e.replyElement && !(Number(e.replyElement.senderUid) > 0) && typeof (e.replyElement as any).senderUidStr === 'string') {
        const uin = await this.uinOf((e.replyElement as any).senderUidStr);
        elements.push(uin ? { ...e, replyElement: { ...e.replyElement, senderUid: String(uin) } } : e);
      } else elements.push(e);
    }
    return { ...nt, elements };
  }

  private async uinOf(uid: string): Promise<number | null> {
    if (this.uids.has(uid)) return this.uids.get(uid)!;
    const hit = await maybeOne<{ uin: number }>(
      this.db,
      sql`select peer_id as uin from peers where qq_account_id = ${this.qqAccountId} and kind = 'user' and uid = ${uid}
          union all select uin from qq_accounts where id = ${this.qqAccountId} and uid = ${uid} limit 1`,
    );
    const uin = hit ? Number(hit.uin) : null;
    this.uids.set(uid, uin);
    return uin;
  }

  /**
   * 预检已经唯一对应到文件的媒体：先拷进媒体库（去重、派生版本照常），再让消息直接引用（不进下载队列）。
   * 对应不上的由 importMessages 记为 expired。
   */
  private async knownMedia(media: IncomingMedia[], elements: NtElement[], links: Record<string, MediaLink>, nodePath: string, opts: ApplyOptions): Promise<Map<number, ReusableBlob>> {
    const known = new Map<number, ReusableBlob>();
    const owners = mediaElements(elements);
    for (const m of media) {
      const element = owners[m.ord];
      // 定位信息只在实时消息里用来向 NapCat 换下载链接；导入的媒体要么已拷入、要么记为拿不到，不留。
      delete (m as { locator?: unknown }).locator;
      const link = element === undefined ? undefined : links[`${nodePath}:${element}`];
      if (link?.status !== 'resolved' || !link.sha256) { this.count(`media_${link?.status ?? 'unlinked'}`); continue; }
      const blob = await this.ensureBlob(link.sha256, m.kind, opts);
      if (blob) known.set(m.ord, blob);
    }
    return known;
  }

  private async ensureBlob(sha256: string, kind: string, opts: ApplyOptions): Promise<ReusableBlob | null> {
    if (this.blobs.has(sha256)) return this.blobs.get(sha256)!;
    let blob = await findBlobBySha256(this.db, sha256);
    if (blob) this.count('media_reused');
    else if (opts.dryRun) this.count('media_would_copy');
    else {
      const file = path.join(opts.stagingDir, `${randomUUID()}.part`);
      try {
        const got = await this.timed('extract', () => this.reader.request({ command: 'extract', sha256, path: file }));
        if (got.missing) this.count('media_extract_failed');
        else {
          await this.timed('store', () => this.media.storeBlob(createReadStream(file), { kind, expectedSha256: sha256 }));
          await this.timed('derive', async () => { await this.processor?.process(sha256, kind); });
          blob = await findBlobBySha256(this.db, sha256);
          this.count('media_copied');
        }
      } finally {
        await fs.rm(file, { force: true });
      }
    }
    this.blobs.set(sha256, blob);
    if (this.blobs.size > 20000) this.blobs.clear();
    return blob;
  }

  /** 合并转发：备份里节点内容是全的，写进 forward_bundles（生产原来要现场向 QQ 拉，老记录多半已经拉不到）。 */
  private async fillForward(ctx: ChatContext, r: ExportRecord, seq: number, opts: ApplyOptions): Promise<void> {
    if (opts.dryRun) { this.count('would_store_forward'); return; }
    const chat = await maybeOne<{ id: number }>(
      this.db,
      sql`select id from chats where qq_account_id = ${opts.qqAccountId} and scene = ${ctx.scene} and peer_id = ${ctx.peerId}`,
    );
    if (!chat) return;
    for (const level of r.forward ?? []) {
      const nodes: ForwardNodeInput[] = [];
      const known: Map<number, ReusableBlob>[] = [];
      for (const node of level.nodes) {
        const nt = await this.resolveUids(node.nt);
        const action = mapRawMessage(nt, { selfUin: this.selfUin, source: 'backfill' });
        if (action.type !== 'message') continue;
        const m = action.message;
        known.push(await this.knownMedia(m.media, nt.elements, r.media, node.sourcePath.join('.'), opts));
        nodes.push({
          senderId: m.senderId,
          senderName: String(nt.sendMemberName || nt.sendNickName || m.senderId),
          time: m.time, msgId: '', segments: m.segments, media: m.media,
        });
      }
      const existing = await maybeOne<{ state: string }>(
        this.db,
        sql`select state from forward_bundles where chat_id = ${chat.id} and message_seq = ${seq} and path = ${level.path}`,
      );
      if (existing?.state === 'ready') { this.count('forward_known'); continue; }
      await retrying(() => this.ingest.storeForward(opts.qqAccountId, chat.id, seq, level.path, nodes.length ? nodes : null, { known, missing: 'expired' }));
      this.count('forward_stored');
    }
  }

  // ---------- 灰条、撤回、通话 ----------

  private async applyTips(ctx: ChatContext, records: ExportRecord[], opts: ApplyOptions): Promise<void> {
    const events: Parameters<IngestService['importChatEvents']>[3][number][] = [];
    for (const r of records) {
      const time = Number(r.nt.msgTime);
      for (const tip of r.tips ?? []) {
        const revoke = tip.grayTip?.subElementType === 1 ? tip.grayTip.revokeElement : null;
        if (revoke) { await this.applyRecall(ctx, r, tip, revoke, opts); continue; }
        // 灰条的 JSON 里 \u0000 转义解析后才变成 NUL，进来时的清理管不到，生成后再清一次。
        const event = stripNul(tip.kind === 'poke' ? await this.pokeEvent(ctx, tip, time) : await this.tipEvent(ctx, r, tip, time));
        if (!event) { await this.note(r, 'tip_unmapped', { type: tip.type }); continue; }
        if (await this.timed('event_dedup', () => this.eventKnown(ctx, event))) { this.count(`${event.kind}_duplicate`); continue; }
        const version = this.eventVersion(ctx, time);
        events.push({ ...event, ...(version === undefined ? {} : { version }) });
        this.count(`${event.kind}_${opts.dryRun ? 'would_insert' : 'inserted'}`);
      }
    }
    if (events.length && !opts.dryRun) await this.timed('events', () => retrying(() => this.ingest.importChatEvents(opts.qqAccountId, ctx.scene, ctx.peerId, events)));
  }

  /** 拍一拍：和生产实时收到的一样存成 poke 事件，rawInfo 用灰条里的人和文字（<qq>/<img>/<nor>）。 */
  private async pokeEvent(ctx: ChatContext, tip: Tip, time: number) {
    const xml = tip.grayTip?.xmlElement?.content as string | undefined;
    const json = tip.grayTip?.jsonGrayTipElement?.jsonStr as string | undefined;
    let items: Record<string, string>[] = [];
    if (json) { try { items = (JSON.parse(json) as { items?: Record<string, string>[] }).items ?? []; } catch { items = []; } }
    else if (xml) {
      for (const m of xml.matchAll(/<(qq|img|nor)\b([^>]*?)\/?>/g)) {
        const attrs = Object.fromEntries([...m[2]!.matchAll(/(\w+)="([^"]*)"/g)].map((a) => [a[1]!, a[2]!]));
        items.push(m[1] === 'qq' ? { type: 'qq', uid: attrs.uin ?? '', nm: attrs.nm ?? '', col: attrs.col ?? '' }
          : m[1] === 'img' ? { type: 'img', src: attrs.src ?? '', jp: attrs.jp ?? '' } : { type: 'nor', txt: attrs.txt ?? '' });
      }
    }
    const people = items.filter((i) => i.type === 'qq' && i.uid);
    if (!people.length) return null;
    const actorId = (await this.uinOf(people[0]!.uid!)) ?? undefined;
    const targetId = people[1] ? ((await this.uinOf(people[1].uid!)) ?? undefined) : undefined;
    // source 标出是导入的（gray_tip 同样带），需要时能精确找出导入写了哪些事件。
    return { kind: 'poke' as const, time, ...(actorId ? { actorId } : {}), ...(targetId ? { targetId } : {}), data: { rawInfo: items, source: 'backup' } };
  }

  /**
   * 其余灰条（进群邀请、打卡、回应、动态……）和通话记录：生产没有对应事件种类的存成 gray_tip，
   * data.text 是客户端显示的一行字（MessageRow 的 gray_tip 分支读 text），segments 带人，原元素留在 backupElement。
   */
  private async tipEvent(ctx: ChatContext, r: ExportRecord, tip: Tip, time: number) {
    let segments: Segment[] | null = tip.grayTip ? grayTipSegments(tip.grayTip, ctx.scene) : null;
    if (!segments && tip.dynamic) {
      const text = (tip.dynamic.descriptions ?? []).map((d) => d.text).filter(Boolean).join(' ');
      segments = text ? [{ type: 'text', text }] : null;
    }
    if (!segments && tip.savedText) segments = [{ type: 'text', text: tip.savedText }];
    if (!segments && tip.type === 21) segments = [{ type: 'text', text: '通话记录' }];
    if (!segments) return null;
    segments = await resolveTipPeople(this.db, this.qqAccountId, ctx.scene === 'group' ? ctx.peerId : null, segments);
    const text = segments.map((s) => (s.type === 'text' ? s.text : s.type === 'mention' ? (s.name || (s.userId ? String(s.userId) : '某人')) : '')).join('');
    const element = r.nt.elements.find((e) => e.elementType === tip.type);
    return {
      kind: 'gray_tip' as const, time,
      data: { text, segments, source: 'backup', elementType: tip.type, ...(element?.backupElement ? { backupElement: element.backupElement } : {}) },
    };
  }

  /** 生产里同一时间（±1 秒）已有同种事件就算已有（实时收到过）；拍一拍还要求发起人一致。 */
  private async eventKnown(ctx: ChatContext, e: { kind: string; time: number; actorId?: number; data: Record<string, unknown> }): Promise<boolean> {
    const hit = await maybeOne<{ x: number }>(
      this.db,
      sql`select 1 as x from chat_events ev join chats c on c.id = ev.chat_id
           where c.qq_account_id = ${this.qqAccountId} and c.scene = ${ctx.scene} and c.peer_id = ${ctx.peerId}
             and ev.kind = ${e.kind} and ev.time between to_timestamp(${e.time - 1}) and to_timestamp(${e.time + 1})
             and (${e.actorId ?? null}::bigint is null or ev.actor_id is null or ev.actor_id = ${e.actorId ?? null}::bigint)
             and (${e.kind} <> 'gray_tip' or ev.data->>'text' = ${String(e.data.text ?? '')})
           limit 1`,
    );
    return Boolean(hit);
  }

  /**
   * 撤回提示：手机把被撤回的消息换成了这条提示，seq 就是原消息的 seq（2026-11-04 群 1061418735 两天 115 条逐条核对）。
   * - 生产里已标撤回：跳过；生产里是正常消息（实时漏了撤回通知）：照常标撤回；
   * - 生产里没有（生产离线期间被撤回，QQ 历史也拉不到）：补写一条已撤回的消息，原文有多少存多少。
   */
  private async applyRecall(ctx: ChatContext, r: ExportRecord, tip: Tip, revoke: Record<string, string>, opts: ApplyOptions): Promise<void> {
    const seq = Number(r.nt.msgSeq);
    const time = Number(r.nt.msgTime);
    const row = seq > 0
      ? await maybeOne<{ state: string }>(
          this.db,
          sql`select m.state from messages m join chats c on c.id = m.chat_id
               where c.qq_account_id = ${opts.qqAccountId} and c.scene = ${ctx.scene} and c.peer_id = ${ctx.peerId} and m.seq = ${seq}`,
        )
      : null;
    const operator = (revoke.operatorUid ? await this.uinOf(revoke.operatorUid) : null) ?? 0;
    if (row?.state === 'recalled') { this.count('recall_known'); return; }
    if (row) {
      if (!opts.dryRun) await retrying(() => this.ingest.recall(opts.qqAccountId, ctx.scene, ctx.peerId, seq, operator, time));
      this.count(opts.dryRun ? 'recall_would_apply' : 'recall_applied');
      return;
    }
    if (!(seq > 0)) { await this.note(r, 'recall_without_seq'); return; }
    const sender = (revoke.origMsgSenderUid ? await this.uinOf(revoke.origMsgSenderUid) : null) ?? 0;
    const nt = await this.resolveUids({ ...r.nt, senderUin: String(sender), senderUid: revoke.origMsgSenderUid ?? '', elements: tip.recalled });
    const mapped = mapRawMessage(nt, { selfUin: this.selfUin, source: 'backfill' });
    if (mapped.type !== 'message') { await this.note(r, 'recall_unmappable'); return; }
    const msg: IncomingMessage = { ...mapped.message, senderId: sender, raw: nt, kind: 'normal' };
    if (opts.dryRun) { this.count('recall_would_insert'); return; }
    const known = await this.knownMedia(msg.media, nt.elements, {}, '', opts);
    const version = this.versionOf(ctx, seq, time);
    await retrying(() => this.ingest.importMessages(opts.qqAccountId, ctx.scene, ctx.peerId,
      [{ msg, known, recalled: { by: operator || sender, at: time }, ...(version === undefined ? {} : { version }) }], { readThrough: !ctx.existedAtStart }));
    this.count('recall_inserted');
  }

  /** 表读完：导入新建的会话把最新一页放进增量同步（见 IngestService.promoteImported）。 */
  private async finishTable(table: string, opts: ApplyOptions): Promise<void> {
    if (opts.dryRun) return;
    for (const scene of ['group', 'friend', 'temp'] as Scene[]) {
      const ctx = this.chats.get(`chat:${table}:${scene}`) ?? (await this.reader.request({ command: 'meta_get', key: `chat:${table}:${scene}` })).value as ChatContext | null;
      if (!ctx || ctx.existedAtStart) continue;
      const chat = await maybeOne<{ id: number }>(
        this.db,
        sql`select id from chats where qq_account_id = ${opts.qqAccountId} and scene = ${scene} and peer_id = ${ctx.peerId}`,
      );
      if (chat) this.count('new_chat_first_page', await retrying(() => this.ingest.promoteImported(opts.qqAccountId, chat.id, NEW_CHAT_FIRST_PAGE)));
    }
  }
}
