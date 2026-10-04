// 冷热分层（docs/design.md 4.6）：把不常用的原件下沉到廉价的大硬盘（MEDIA_COLD_ROOT），常用的留在热存储。
// 只移动原件；缩略图、预览图、头像这些小文件始终在热存储（列表要靠它们秒开）。
// 下沉条件（每天跑一次，也可手动执行 / 预览）：
//   1. 按时间：原件多久没被访问（没访问过按入库时间）超过 cold_after_days，且不小于 cold_min_bytes。
//      一个内容被多个会话引用时，取最保守的规则：任一会话设了"永不下沉"就不动，天数和大小门槛取最大值。
//   2. 按会话配额：会话独占原件在热存储里超过 hot_quota_bytes，从最久没访问的开始下沉，直到不超。
//   3. 按全局配额：账号的热存储总量超过全局 hot_quota_bytes，同样按最久没访问先下沉（"永不下沉"的会话除外）。
// 提回：冷存储里的原件被打开时记访问次数（10 分钟内只算一次），累计 3 次就提回热存储。
// 视频的 faststart 版本跟着原件走（它和原件一样大）。
// 冷存储在外接硬盘上，盘可能不在：不在时不下沉、不提回；读到冷存储里的内容时由下载接口从 QQ 取回（见 api/server.ts），
// 盘回来后，那期间被取回的内容在盘上留下的旧文件由 sweepColdOrphans 清掉。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { rows, type Db } from '../db/client.ts';
import type { Scene } from '@qqbridge/domain';
import { tieringRules } from './policies.ts';
import type { MediaService } from './service.ts';

export const PROMOTE_AFTER_ACCESSES = 3;
/** 小于这个大小的内容不为了配额下沉（移来移去不划算）。 */
const QUOTA_MIN_BYTES = 64 * 1024;

export interface TieringCandidate {
  sha256: string;
  size: number;
  reason: 'age' | 'chat_quota' | 'global_quota';
  chatId: number | null;
}

export interface TieringReport {
  candidates: number;
  bytes: number;
  moved: number;
  movedBytes: number;
  byReason: Record<TieringCandidate['reason'], number>;
}

export class TierManager {
  private timer: NodeJS.Timeout | null = null;
  private readonly promoting = new Set<string>();

  constructor(
    private readonly db: Db,
    private readonly media: Pick<MediaService, 'moveTier' | 'touch' | 'hasColdTier' | 'coldAvailable' | 'sweepColdOrphans'>,
    private readonly logger?: Logger,
  ) {}

  get enabled(): boolean {
    return this.media.hasColdTier;
  }

  start(): void {
    if (!this.enabled) return;
    const run = () =>
      void this.runAll().catch((error: unknown) => this.logger?.warn({ err: error }, 'tiering failed'));
    setTimeout(run, 5 * 60_000).unref();
    this.timer = setInterval(run, 24 * 3600_000);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** 原件被访问：记次数，冷存储里的常被打开就提回热存储（后台进行，不耽误这次下载）。 */
  onAccess(sha256: string): void {
    void this.media
      .touch(sha256)
      .then((state) => {
        if (!state || state.tier !== 'cold' || state.accessCount < PROMOTE_AFTER_ACCESSES || this.promoting.has(sha256)) return;
        this.promoting.add(sha256);
        return this.withPlayable([sha256])
          .then((list) => Promise.all(list.map((s) => this.media.moveTier(s, 'hot'))))
          .then(() => this.logger?.info({ sha256 }, 'promoted to hot storage'))
          .finally(() => this.promoting.delete(sha256));
      })
      .catch((error: unknown) => this.logger?.warn({ err: error, sha256 }, 'access tracking failed'));
  }

  async runAll(): Promise<TieringReport[]> {
    if (!this.media.coldAvailable) {
      this.logger?.warn('cold storage is not mounted; skipping tiering');
      return [];
    }
    const orphans = await this.media.sweepColdOrphans();
    if (orphans) this.logger?.info({ orphans }, 'removed orphaned files from cold storage');
    const accounts = await rows<{ id: number }>(this.db, sql`select id from accounts`);
    const reports: TieringReport[] = [];
    for (const a of accounts) {
      const report = await this.run(Number(a.id), false);
      if (report.moved) this.logger?.info({ accountId: a.id, ...report }, 'moved originals to cold storage');
      reports.push(report);
    }
    return reports;
  }

  /** 计算并（dryRun = false 时）执行一轮下沉。 */
  async run(accountId: number, dryRun: boolean): Promise<TieringReport> {
    const candidates = await this.plan(accountId);
    const report: TieringReport = {
      candidates: candidates.length,
      bytes: candidates.reduce((n, c) => n + c.size, 0),
      moved: 0,
      movedBytes: 0,
      byReason: { age: 0, chat_quota: 0, global_quota: 0 },
    };
    for (const c of candidates) report.byReason[c.reason] += 1;
    if (dryRun || !this.enabled || !this.media.coldAvailable) return report;
    for (const c of candidates) {
      try {
        for (const sha of await this.withPlayable([c.sha256])) {
          const bytes = await this.media.moveTier(sha, 'cold');
          if (sha === c.sha256 && bytes) report.moved += 1;
          report.movedBytes += bytes;
        }
      } catch (error) {
        this.logger?.warn({ err: error, sha256: c.sha256 }, 'move to cold storage failed');
      }
    }
    return report;
  }

  /** 这一轮要下沉的原件（不含已在冷存储、已清理、头像和派生版本）。 */
  async plan(accountId: number): Promise<TieringCandidate[]> {
    const rules = await tieringRules(this.db, accountId);
    // 账号下每个会话引用的、仍在热存储里的原件，带上最后访问时间。
    const usage = await rows<{ chat_id: number; scene: Scene; sha256: string; size: number; ref_chats: number; last_active: Date | string }>(
      this.db,
      sql`select u.chat_id, c.scene, b.sha256, b.size, b.ref_chats, coalesce(b.last_access_at, b.created_at) as last_active
            from chat_blob_usage u
            join chats c on c.id = u.chat_id join qq_accounts q on q.id = c.qq_account_id
            join blobs b on b.sha256 = u.sha256
           where q.account_id = ${accountId} and b.state = 'present' and b.tier = 'hot'
             and not exists (select 1 from blob_variants v where v.variant_sha256 = b.sha256 and v.variant <> 'playable')
             and not exists (select 1 from peers p where p.avatar_sha256 = b.sha256)`,
    );
    interface BlobInfo {
      size: number;
      lastActive: number;
      never: boolean;
      days: number;
      minBytes: number;
      chats: number[];
    }
    const blobs = new Map<string, BlobInfo>();
    for (const u of usage) {
      const rule = rules.forChat(Number(u.chat_id), u.scene);
      const info = blobs.get(u.sha256) ?? {
        size: Number(u.size),
        lastActive: new Date(u.last_active).getTime(),
        never: false,
        days: 0,
        minBytes: 0,
        chats: [],
      };
      if (rule.coldAfterDays === null) info.never = true;
      else info.days = Math.max(info.days, rule.coldAfterDays);
      info.minBytes = Math.max(info.minBytes, rule.coldMinBytes);
      info.chats.push(Number(u.chat_id));
      blobs.set(u.sha256, info);
    }

    const picked = new Map<string, TieringCandidate>();
    const now = Date.now();
    // 1. 按时间
    for (const [sha256, b] of blobs) {
      if (b.never || b.size < b.minBytes) continue;
      if (now - b.lastActive > b.days * 86400_000) picked.set(sha256, { sha256, size: b.size, reason: 'age', chatId: null });
    }
    // 2. 按会话配额（只算本会话独占的原件）
    const byChat = new Map<number, { scene: Scene; items: { sha256: string; size: number; lastActive: number }[] }>();
    for (const u of usage) {
      if (Number(u.ref_chats) !== 1) continue;
      const entry = byChat.get(Number(u.chat_id)) ?? { scene: u.scene, items: [] };
      entry.items.push({ sha256: u.sha256, size: Number(u.size), lastActive: new Date(u.last_active).getTime() });
      byChat.set(Number(u.chat_id), entry);
    }
    for (const [chatId, { scene, items }] of byChat) {
      const quota = rules.forChat(chatId, scene).hotQuotaBytes;
      if (quota === null) continue;
      let hot = items.filter((i) => !picked.has(i.sha256)).reduce((n, i) => n + i.size, 0);
      for (const item of items.sort((a, b) => a.lastActive - b.lastActive)) {
        if (hot <= quota) break;
        if (picked.has(item.sha256) || item.size < QUOTA_MIN_BYTES || blobs.get(item.sha256)?.never) continue;
        picked.set(item.sha256, { sha256: item.sha256, size: item.size, reason: 'chat_quota', chatId });
        hot -= item.size;
      }
    }
    // 3. 按全局配额
    if (rules.globalHotQuotaBytes !== null) {
      let hot = [...blobs].filter(([sha]) => !picked.has(sha)).reduce((n, [, b]) => n + b.size, 0);
      const lru = [...blobs].sort((a, b) => a[1].lastActive - b[1].lastActive);
      for (const [sha256, b] of lru) {
        if (hot <= rules.globalHotQuotaBytes) break;
        if (picked.has(sha256) || b.never || b.size < QUOTA_MIN_BYTES) continue;
        picked.set(sha256, { sha256, size: b.size, reason: 'global_quota', chatId: null });
        hot -= b.size;
      }
    }
    return [...picked.values()];
  }

  /** 原件 + 它的 faststart 播放版本（若与原件不同）。 */
  private async withPlayable(shas: string[]): Promise<string[]> {
    const playable = await rows<{ variant_sha256: string }>(
      this.db,
      sql`select variant_sha256 from blob_variants
           where variant = 'playable' and variant_sha256 <> sha256 and sha256 in (${sql.join(
             shas.map((s) => sql`${s}`),
             sql`, `,
           )})`,
    );
    return [...shas, ...playable.map((p) => p.variant_sha256)];
  }
}
