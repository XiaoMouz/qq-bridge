// 聊天日历（日期选择器）：每天、每小时的消息数和每天一张图片；跳到某个时刻的第一条消息。
// 2026-11-08 实测最大的群（约 30 万条、9 万张图）：按小时计数走 (chat_id, time) 索引只扫索引，热缓存约 0.2 秒；
// 每天一张图约 0.8 秒。结果按 (会话, 时区) 缓存 10 分钟，过期先给旧的、后台重算。
import { sql } from 'drizzle-orm';
import { maybeOne, rows, type Db } from '../db/client.ts';
import { SharedResults, withStatementTimeout } from '../db/shared.ts';
import { NotFoundError } from './difference.ts';

export interface CalendarDay {
  /** 当地这天 0 点（unix 秒）。 */
  day: number;
  count: number;
  hours: number[];
  preview: string | null;
}

const TTL_MS = 10 * 60_000;
const TIMEOUT_MS = 60_000;

export class ChatCalendar {
  private shared = new SharedResults();

  constructor(private readonly db: Db) {}

  async days(accountId: number, chatId: number, offsetMinutes: number): Promise<CalendarDay[]> {
    await this.owned(accountId, chatId);
    const offset = Math.max(-14 * 60, Math.min(14 * 60, Math.trunc(offsetMinutes)));
    return this.shared.run(`calendar:${chatId}:${offset}`, () => this.load(chatId, offset), { ttlMs: TTL_MS, stale: true });
  }

  async messageAt(accountId: number, chatId: number, time: Date): Promise<{ seq: number; time: Date } | null> {
    await this.owned(accountId, chatId);
    const at = time.toISOString();
    const row =
      (await maybeOne<{ seq: number; time: string }>(
        this.db,
        sql`select seq, time from messages where chat_id = ${chatId} and time >= ${at}::timestamptz order by time, seq limit 1`,
      )) ??
      (await maybeOne<{ seq: number; time: string }>(
        this.db,
        sql`select seq, time from messages where chat_id = ${chatId} and time < ${at}::timestamptz order by time desc, seq desc limit 1`,
      ));
    return row ? { seq: Number(row.seq), time: new Date(row.time) } : null;
  }

  private async owned(accountId: number, chatId: number) {
    const row = await maybeOne(
      this.db,
      sql`select 1 from chats c join qq_accounts q on q.id = c.qq_account_id where c.id = ${chatId} and q.account_id = ${accountId}`,
    );
    if (!row) throw new NotFoundError(`chat ${chatId} not found`);
  }

  private async load(chatId: number, offset: number): Promise<CalendarDay[]> {
    const shift = offset * 60;
    // 小时号 = floor((unix 秒 + 时区) / 3600)：纯算术，不受数据库会话时区影响，也不妨碍只扫索引。
    const [hours, previews] = await withStatementTimeout(this.db, TIMEOUT_MS, async (tx) => {
      // 默认计划会走 version 索引再回表（冷缓存 10 秒），关掉位图扫描让它只扫 (chat_id, time) 索引。
      await tx.execute(sql`set local enable_bitmapscan = off`);
      const h = await rows<{ h: number; n: number }>(
        tx,
        sql`select floor((extract(epoch from time) + ${shift}) / 3600)::bigint as h, count(*)::int as n
              from messages where chat_id = ${chatId} group by 1 order by 1`,
      );
      const p = await rows<{ d: number; sha: string }>(
        tx,
        sql`select x.d, coalesce((select v.variant_sha256 from blob_variants v where v.sha256 = x.sha256 and v.variant = 'thumb' limit 1), x.sha256) as sha
              from (
                select distinct on (y.d) y.d, y.sha256
                  from (
                    select floor((extract(epoch from r.time) + ${shift}) / 86400)::bigint as d, r.sha256, b.size
                      from media_refs r join blobs b on b.sha256 = r.sha256 and b.state = 'present'
                     where r.chat_id = ${chatId} and r.kind = 'image' and r.role = 'attachment'
                  ) y
                 order by y.d, y.size desc
              ) x`,
      );
      return [h, p] as const;
    });
    const preview = new Map(previews.map((p) => [Number(p.d), p.sha]));
    const days = new Map<number, CalendarDay>();
    for (const { h, n } of hours) {
      const hour = Number(h);
      const index = Math.floor(hour / 24);
      let day = days.get(index);
      if (!day) {
        day = { day: index * 86400 - shift, count: 0, hours: Array(24).fill(0), preview: preview.get(index) ?? null };
        days.set(index, day);
      }
      day.count += n;
      day.hours[hour - index * 24] = n;
    }
    return [...days.values()];
  }
}
