// 原件清理（docs/design.md 4.6"策略"）：
// - 用户主动清理（ExecuteCleanup）：选中的出现以后不再需要原件（media_refs.keep_original = false），
//   再逐个判断：所有引用方都不需要原件的内容才删除原件；
// - 按保留策略的定时清理（runRetention）：超过保留天数的出现不再需要原件，同样按"保留最久者优先"判断。
// 缩略图、预览图是独立的内容（不在 media_refs 里），不会被清理；没有任何出现记录的内容也不在这里处理。
import { originalPurgeable, resolveRule, type RefRetention, type Scene } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { rows, type Db } from '../db/client.ts';
import { sqlList } from '../sync/rows.ts';
import { retentionPolicies } from './policies.ts';
import type { CleanupCriteria, MediaService } from './service.ts';

export interface CleanupReport {
  refCount: number;
  blobCount: number;
  purgedBlobCount: number;
  freedBytes: number;
  keptSharedBlobCount: number;
}

export interface RetentionReport {
  examined: number;
  purged: number;
  freedBytes: number;
}

export class MediaCleaner {
  constructor(
    private readonly db: Db,
    private readonly media: MediaService,
    private readonly logger?: Logger,
  ) {}

  /** 执行"清理某会话里符合条件的媒体原件"（条件与 PlanCleanup 相同）。 */
  async execute(accountId: number, chatId: number, criteria: CleanupCriteria, nowSec = Math.floor(Date.now() / 1000)): Promise<CleanupReport> {
    const plan = await this.media.planCleanup(accountId, chatId, criteria, nowSec);
    if (plan.candidateRefIds.length === 0) {
      return { refCount: 0, blobCount: 0, purgedBlobCount: 0, freedBytes: 0, keptSharedBlobCount: 0 };
    }
    const candidates = await rows<{ sha256: string }>(
      this.db,
      sql`update media_refs set keep_original = false where id in ${sqlList(plan.candidateRefIds)} returning sha256`,
    );
    const shas = [...new Set(candidates.map((c) => c.sha256))];
    const { purged, freedBytes } = await this.purgeWhereAllowed(shas, nowSec);
    return {
      refCount: plan.candidateRefIds.length,
      blobCount: shas.length,
      purgedBlobCount: purged,
      freedBytes,
      keptSharedBlobCount: shas.length - purged,
    };
  }

  /**
   * 按保留策略清理：找出"有出现已超过保留期（或已被标记不需要原件）"的内容，逐个按全部引用方判断。
   * 分页扫描（按 sha256 递增），每轮把所有候选都看一遍。
   */
  async runRetention(nowSec = Math.floor(Date.now() / 1000), pageSize = 500): Promise<RetentionReport> {
    const [{ min_days: minDays } = { min_days: null }] = await rows<{ min_days: number | null }>(
      this.db,
      sql`select min(keep_original_days)::int as min_days from storage_policies where keep_original_days >= 0`,
    );
    const report: RetentionReport = { examined: 0, purged: 0, freedBytes: 0 };
    const cutoff = minDays === null ? null : new Date((nowSec - minDays * 86_400) * 1000).toISOString();
    let after = '';
    for (;;) {
      const page = await rows<{ sha256: string }>(
        this.db,
        sql`select distinct r.sha256 from media_refs r join blobs b on b.sha256 = r.sha256
             where b.state = 'present' and r.sha256 > ${after}
               and (r.keep_original = false ${cutoff ? sql`or r.time < ${cutoff}::timestamptz` : sql``})
             order by r.sha256
             limit ${pageSize}`,
      );
      if (page.length === 0) break;
      after = page[page.length - 1]!.sha256;
      report.examined += page.length;
      const { purged, freedBytes } = await this.purgeWhereAllowed(
        page.map((p) => p.sha256),
        nowSec,
      );
      report.purged += purged;
      report.freedBytes += freedBytes;
      if (page.length < pageSize) break;
    }
    if (report.purged > 0) this.logger?.info(report, 'retention cleanup purged originals');
    return report;
  }

  /**
   * 刚下载好的内容：有引用方标了"不需要原件"（按需会话里的图片）时，若所有引用方都允许就立刻删原件，
   * 缩略图和预览图已经生成好了。看大图时再从 QQ 拉（见 api/server.ts）。
   */
  async purgeIfUnneeded(sha256: string, nowSec = Math.floor(Date.now() / 1000)): Promise<boolean> {
    const marked = await rows(this.db, sql`select 1 from media_refs where sha256 = ${sha256} and keep_original = false limit 1`);
    if (marked.length === 0) return false;
    const { purged } = await this.purgeWhereAllowed([sha256], nowSec);
    return purged > 0;
  }

  /** 所有引用方都不再需要原件的内容，删除原件。 */
  private async purgeWhereAllowed(shas: string[], nowSec: number): Promise<{ purged: number; freedBytes: number }> {
    let purged = 0;
    let freedBytes = 0;
    for (const sha of await this.purgeable(shas, nowSec)) {
      const result = await this.media.purgeOriginal(sha);
      if (result.purged) {
        purged += 1;
        freedBytes += result.size;
      }
    }
    return { purged, freedBytes };
  }

  /** 按"保留最久者优先"判断哪些内容的原件可以删除（必须至少有一处出现记录）。 */
  async purgeable(shas: readonly string[], nowSec: number): Promise<string[]> {
    if (shas.length === 0) return [];
    const refs = await rows<{
      sha256: string;
      chat_id: number;
      scene: Scene;
      account_id: number;
      t: number;
      keep_original: boolean | null;
    }>(
      this.db,
      sql`select r.sha256, r.chat_id, c.scene, q.account_id, extract(epoch from r.time)::bigint as t, r.keep_original
            from media_refs r join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
           where r.sha256 in ${sqlList([...shas])}`,
    );
    const policies = await retentionPolicies(this.db, [...new Set(refs.map((r) => r.account_id))]);
    const bySha = new Map<string, RefRetention[]>();
    for (const r of refs) {
      const list = bySha.get(r.sha256) ?? [];
      list.push({
        time: r.t,
        override: r.keep_original,
        rule: resolveRule(policies.get(r.account_id) ?? [], { chatId: r.chat_id, scene: r.scene }),
      });
      bySha.set(r.sha256, list);
    }
    return shas.filter((sha) => {
      const list = bySha.get(sha);
      return list !== undefined && list.length > 0 && originalPurgeable(list, nowSec);
    });
  }
}
