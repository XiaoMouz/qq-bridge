// 存档完整性（docs/design.md 4.5 第 2、4 条）：
// - chats.verified_ranges 记"已经和 QQ 核对过"的 seq 区间：这些区间里没存的 seq 就是 QQ 上也没有（或已无法拉取）。
//   已存的消息本身也算已知。会话里 [最早一条, 最新一条] 之间既没存、也没核对过的部分就是缺口。
// - 缺口补齐（HoleFiller.schedule）：对账之后和定时（默认 10 分钟）各跑一次，正在看的会话优先、新缺口优先，
//   按 requestIntervalMs 限速；每轮最多 maxRequests 次请求，剩下的下一轮接着补。
// - 懒回填（backfillOlder）：客户端往上翻页翻过了服务端最早的一条时，现场向 QQ 拉一页。
// - 深度归档（chats.deep_archive_at）：对指定会话从 seq 1 补起，直到 QQ 那边拉不到更早的；排在普通缺口之后。
// - 单条消息入库失败只跳过这一条（记日志，不算已核对，下一轮再试），不影响同一页的其他消息。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import { sqlList } from '../sync/rows.ts';
import type { ActiveChats } from '../sync/active-chats.ts';
import { SourceUnavailableError } from '../media/source.ts';
import type { UpstreamHub } from './hub.ts';
import type { InboxProcessor } from './inbox.ts';
import { int, mapRawMessage } from './napcat/map.ts';
import { NtChatType, type NtRawMessage } from './napcat/types.ts';

/** QQ 的"没有更早的消息了"。 */
export const NO_MORE_MESSAGES = 2004000;

export interface HistoryChat {
  id: number;
  qqAccountId: number;
  selfUin: number;
  scene: 'friend' | 'group';
  peerId: number;
  /** 好友的 NT uid（知道就带上，插件不用再按 QQ 号查）。 */
  peerUid?: string;
}

export interface FetchResult {
  /** 入库（或已存在）的消息数。 */
  messages: number;
  failed: number;
  requests: number;
  /** QQ 那边再往前已经没有消息了。 */
  exhausted: boolean;
}

export interface HistoryOptions {
  pageSize?: number;
  requestIntervalMs?: number;
  /** 一轮缺口补齐最多发多少次请求。 */
  maxRequests?: number;
  intervalMs?: number;
  logger?: Logger;
  sleep?: (ms: number) => Promise<void>;
}

export interface Hole {
  chatId: number;
  /** 缺口 [lower, upper)。 */
  lower: number;
  upper: number;
  /** 深度归档：服务端最早一条之前的历史（排在普通缺口之后补）。 */
  deep?: boolean;
}

export class HoleFiller {
  private readonly running = new Map<number, Promise<void>>();
  private readonly holeQueries = new Map<string, Promise<Hole[]>>();
  /**
   * 每个会话上次算出的缺口，按会话指纹（chat_pts、已核对区间、深度存档）复用。
   * 2026-10-24 实测：状态页每分钟三次重算全部会话的缺口，每次约 0.5–14 秒（冷缓存时读 5 万个块），是数据库最耗时的查询；
   * 消息的任何写入都会推进 chat_pts，指纹没变的会话缺口不可能变，只重算变了的会话。
   */
  private readonly holeCache = new Map<number, { fingerprint: string; holes: Hole[]; at: number }>();
  /** 状态页触发的后台重算（每个 QQ 号同时只跑一个）。 */
  private readonly holeRefresh = new Map<number, Promise<unknown>>();
  private readonly o: Required<Omit<HistoryOptions, 'logger'>> & Pick<HistoryOptions, 'logger'>;
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly db: Db,
    private readonly hub: Pick<UpstreamHub, 'call'>,
    private readonly inbox: Pick<InboxProcessor, 'applyAction'>,
    private readonly activeChats: Pick<ActiveChats, 'chatIds'> | null,
    opts: HistoryOptions = {},
  ) {
    this.o = {
      pageSize: 50,
      requestIntervalMs: 1000,
      maxRequests: 600,
      intervalMs: 10 * 60_000,
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      ...opts,
    };
  }

  /** 定时对所有 QQ 号跑缺口补齐。 */
  start(accounts: () => Promise<number[]>): void {
    this.timer = setInterval(() => {
      void accounts().then((ids) => ids.forEach((id) => this.schedule(id)));
    }, this.o.intervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** 安排一轮缺口补齐（同一个 QQ 号同时只跑一轮）。 */
  schedule(qqAccountId: number): void {
    if (this.running.has(qqAccountId)) return;
    const run = this.fillHoles(qqAccountId)
      .then((report) => {
        if (report.holes > 0) this.o.logger?.info({ qqAccountId, ...report }, 'history holes filled');
      })
      .catch((error: unknown) => {
        if (error instanceof SourceUnavailableError) return; // QQ 离线：下一轮再补
        this.o.logger?.warn({ err: error, qqAccountId }, 'history hole filling failed');
      })
      .finally(() => this.running.delete(qqAccountId));
    this.running.set(qqAccountId, run);
  }

  async idle(): Promise<void> {
    await Promise.all([...this.running.values()]);
  }

  async fillHoles(
    qqAccountId: number,
  ): Promise<{ holes: number; messages: number; failed: number; requests: number; remaining: number; chatErrors: number }> {
    const holes = await this.holes(qqAccountId);
    const active = new Set(this.activeChats?.chatIds() ?? []);
    holes.sort(
      (a, b) =>
        Number(Boolean(a.deep)) - Number(Boolean(b.deep)) || Number(active.has(b.chatId)) - Number(active.has(a.chatId)) || b.upper - a.upper,
    );
    const report = { holes: holes.length, messages: 0, failed: 0, requests: 0, remaining: 0, chatErrors: 0 };
    const chats = new Map<number, HistoryChat | null>();
    const broken = new Set<number>();
    for (const hole of holes) {
      if (report.requests >= this.o.maxRequests || broken.has(hole.chatId)) {
        report.remaining += 1;
        continue;
      }
      if (!chats.has(hole.chatId)) chats.set(hole.chatId, await this.chat(hole.chatId));
      const chat = chats.get(hole.chatId);
      if (!chat) continue;
      try {
        const result = await this.fetchOlder(chat, hole.upper - 1, hole.lower - 1, hole.upper - hole.lower, {
          maxRequests: this.o.maxRequests - report.requests,
          throttleFirst: report.requests > 0,
        });
        report.messages += result.messages;
        report.failed += result.failed;
        report.requests += result.requests;
      } catch (error) {
        if (error instanceof SourceUnavailableError) throw error; // QQ 离线：整轮停下，下一轮再来
        // 一个会话出错只跳过这个会话（本轮剩下的缺口也先不碰），不拖累其他会话。
        broken.add(hole.chatId);
        report.chatErrors += 1;
        report.requests += 1;
        this.o.logger?.warn({ err: error, chatId: hole.chatId, hole: [hole.lower, hole.upper] }, 'history hole failed');
      }
    }
    return report;
  }

  /** 某个 QQ 号下所有会话的缺口（按会话的 [最早一条, 最新一条] 计算）。 */
  async holes(qqAccountId: number, chatId?: number, opts: { maxStaleMs?: number } = {}): Promise<Hole[]> {
    // 2026-10-19：状态页并发请求曾占满连接池，导致实时收件箱无法入库。
    // 合并尚未完成的同范围查询；结果按会话指纹复用（见 holeCache）。
    // maxStaleMs：只给状态页用。忙的群 20 秒里 chat_pts 就会变好几次，状态页每次都要重算这些群（约 150 ms）；
    // 状态页的数字晚一分钟无妨，补历史自己调用时仍按指纹要最新的。
    const key = `${qqAccountId}:${chatId ?? 'all'}:${opts.maxStaleMs ?? 0}`;
    let pending = this.holeQueries.get(key);
    if (!pending) {
      pending = this.queryHoles(qqAccountId, chatId, opts.maxStaleMs ?? 0).finally(() => this.holeQueries.delete(key));
      this.holeQueries.set(key, pending);
    }
    // 补历史会按优先级原地排序，调用方不能共享可变数组或条目。
    return (await pending).map((hole) => ({ ...hole }));
  }

  private async queryHoles(qqAccountId: number, chatId: number | undefined, maxStaleMs: number): Promise<Hole[]> {
    const chats = await rows<{ id: number; fingerprint: string }>(
      this.db,
      sql`select id, chat_pts || '|' || verified_ranges::text || '|' || coalesce(deep_archive_at::text, '') as fingerprint
            from chats where qq_account_id = ${qqAccountId} and scene in ('friend', 'group')
             ${chatId === undefined ? sql`` : sql`and id = ${chatId}`}`,
    );
    const now = Date.now();
    const changed = chats.filter((c) => this.holeCache.get(c.id)?.fingerprint !== c.fingerprint);
    if (maxStaleMs > 0) {
      // 状态页：有过结果就先用（忙的群重算一次 100–370 ms），过了容忍时间的放到后台重算；从没算过的才当场算。
      const missing = changed.filter((c) => !this.holeCache.has(c.id));
      const expired = changed.filter((c) => this.holeCache.has(c.id) && now - this.holeCache.get(c.id)!.at > maxStaleMs);
      if (missing.length > 0) await this.refreshHoles(qqAccountId, missing, now);
      if (expired.length > 0 && !this.holeRefresh.has(qqAccountId)) {
        const task = this.refreshHoles(qqAccountId, expired, now)
          .catch((error: unknown) => this.o.logger?.warn({ err: error }, 'background hole refresh failed'))
          .finally(() => this.holeRefresh.delete(qqAccountId));
        this.holeRefresh.set(qqAccountId, task);
      }
    } else if (changed.length > 0) {
      await this.refreshHoles(qqAccountId, changed, now);
    }
    if (chatId === undefined) {
      // 已经不在列表里的会话（删掉、换了账号）不再占着缓存。
      const live = new Set(chats.map((c) => c.id));
      for (const id of this.holeCache.keys()) if (!live.has(id)) this.holeCache.delete(id);
    }
    return chats
      .map((c) => c.id)
      .sort((x, y) => x - y)
      .flatMap((id) => this.holeCache.get(id)?.holes ?? []);
  }

  private async refreshHoles(qqAccountId: number, chats: { id: number; fingerprint: string }[], at: number): Promise<void> {
    const fresh = await this.computeHoles(qqAccountId, chats.map((c) => c.id));
    for (const c of chats) this.holeCache.set(c.id, { fingerprint: c.fingerprint, holes: fresh.get(c.id) ?? [], at });
  }

  private async computeHoles(qqAccountId: number, chatIds: number[]): Promise<Map<number, Hole[]>> {
    const list = await rows<{ chat_id: number; lower: string; upper: string; deep: boolean }>(
      this.db,
      // 2026-10-19 实测：先把全部消息与会话范围连接再聚合会产生约 201 MiB 临时写入。
      // 按会话聚合只携带 seq，保留原有缺口语义，并避免宽行哈希聚合落盘。
      sql`select c.id as chat_id, lower(r) as lower, upper(r) as upper, upper(r) <= m.lo as deep
            from chats c cross join lateral (
              select min(seq) as lo, max(seq) as hi, range_agg(int8range(seq, seq + 1)) as k
                from messages where chat_id = c.id
            ) m cross join lateral unnest(
              int8multirange(int8range(case when c.deep_archive_at is not null then 1 else m.lo end, m.hi + 1))
                - (c.verified_ranges + coalesce(m.k, '{}'))
            ) r
           where c.qq_account_id = ${qqAccountId} and c.scene in ('friend', 'group') and m.lo is not null
             and c.id in ${sqlList(chatIds)}
           order by c.id, lower(r)`,
    );
    const out = new Map<number, Hole[]>();
    for (const h of list) {
      const hole: Hole = { chatId: h.chat_id, lower: Number(h.lower), upper: Number(h.upper), ...(h.deep ? { deep: true } : {}) };
      const group = out.get(h.chat_id);
      if (group) group.push(hole);
      else out.set(h.chat_id, [hole]);
    }
    return out;
  }

  /** 这一条还没入库就单独向 QQ 要（见 outbox/confirm.ts）。返回是否已在库里。 */
  async ensureMessage(chatId: number, seq: number): Promise<boolean> {
    const has = async () =>
      Boolean(await maybeOne(this.db, sql`select 1 from messages where chat_id = ${chatId} and seq = ${seq}`));
    if (await has()) return true;
    const chat = await this.chat(chatId);
    if (!chat) return false;
    // 2026-10-25 实测：getMsgsBySeqAndCount 要 1 条时返回空列表（要 4 条才带上这一条），
    // 空页会被当成「这段没有消息」记为核对过，所以连前面几条一起要。已入库的重复入库是幂等的。
    await this.fetchOlder(chat, seq, Math.max(0, seq - 5), 5, { maxRequests: 1, throttleFirst: false });
    return has();
  }

  /** 懒回填：拉 belowSeq 之前的一页。QQ 那边已经到头（或之前确认过到头）时返回 0。 */
  async backfillOlder(chatId: number, belowSeq: number, limit: number): Promise<number> {
    if (belowSeq <= 1) return 0;
    const known = await maybeOne<{ done: boolean }>(
      this.db,
      sql`select verified_ranges @> int8range(1, ${belowSeq}) as done from chats where id = ${chatId}`,
    );
    if (!known || known.done) return 0;
    const chat = await this.chat(chatId);
    if (!chat) return 0;
    const result = await this.fetchOlder(chat, belowSeq - 1, 0, limit, { maxRequests: 3, throttleFirst: false });
    return result.messages;
  }

  /**
   * 从 fromSeq（含）往前拉，直到 stopAt（不含）或拉够 budget 条；每页入库后把这一页覆盖的区间记为已核对。
   * 对账预热、缺口补齐、懒回填共用。
   */
  async fetchOlder(
    chat: HistoryChat,
    fromSeq: number,
    stopAt: number,
    budget: number,
    opts: { maxRequests?: number; throttleFirst?: boolean } = {},
  ): Promise<FetchResult> {
    const result: FetchResult = { messages: 0, failed: 0, requests: 0, exhausted: false };
    let from = fromSeq;
    while (result.messages < budget && from > stopAt && result.requests < (opts.maxRequests ?? Infinity)) {
      if (result.requests > 0 || opts.throttleFirst !== false) {
        await this.o.sleep(Math.round(this.o.requestIntervalMs * (1 + Math.random() * 0.5)));
      }
      const count = Math.min(this.o.pageSize, budget - result.messages, from - stopAt);
      const page = await this.hub
        .call<{ result?: number; errMsg?: string; messages?: NtRawMessage[] }>(chat.qqAccountId, 'x.history', {
          chatType: chat.scene === 'group' ? NtChatType.group : NtChatType.friend,
          peerUin: String(chat.peerId),
          ...(chat.peerUid ? { peerUid: chat.peerUid } : {}),
          fromSeq: String(from),
          count,
          desc: true,
          includeCurrent: true,
        })
        .catch((error: unknown) => {
          if (error instanceof SourceUnavailableError) throw error;
          throw new Error(`x.history failed for chat ${chat.id} at ${from}: ${error instanceof Error ? error.message : error}`, { cause: error });
        });
      result.requests += 1;
      // 2004000 "no any more msg"：QQ 那边 from 及之前已经没有消息了，与空页同义。
      const noMore = page?.result === NO_MORE_MESSAGES;
      if (page?.result && !noMore) throw new Error(`x.history returned ${page.result} ${page.errMsg ?? ''} for chat ${chat.id} at ${from}`);
      const all = noMore ? [] : (page?.messages ?? []);
      const messages = all.filter((m) => {
        const seq = int(m.msgSeq);
        return seq > stopAt && seq <= from;
      });
      if (all.length === 0) {
        // QQ 那边 from 及之前已经没有消息：整段都核对过了。
        await this.markVerified(chat.id, stopAt + 1, from + 1, []);
        result.exhausted = true;
        break;
      }
      if (messages.length === 0) {
        // QQ 返回的全都早于这段（seq <= stopAt）：这段在 QQ 上本来就没有消息（删除、撤回后清掉等），记为核对过。
        // 返回了比 from 还新的（不该发生）就什么也不记，避免误判。
        if (all.every((m) => int(m.msgSeq) <= stopAt)) await this.markVerified(chat.id, stopAt + 1, from + 1, []);
        break;
      }
      const failedSeqs: number[] = [];
      for (const raw of messages) {
        const action = mapRawMessage(raw, { selfUin: chat.selfUin, source: 'backfill' });
        const outcome = await this.inbox.applyAction(chat.qqAccountId, action);
        if (outcome.state === 'failed') {
          failedSeqs.push(int(raw.msgSeq));
          this.o.logger?.warn({ chatId: chat.id, seq: int(raw.msgSeq), error: outcome.error }, 'history message failed');
        }
      }
      const lowest = Math.min(...messages.map((m) => int(m.msgSeq)));
      // 这一页覆盖 [lowest, from]。不够一页不能说明前面没有了（QQ 单次返回条数可能有上限），只认空页。
      await this.markVerified(chat.id, lowest, from + 1, failedSeqs);
      result.messages += messages.length - failedSeqs.length;
      result.failed += failedSeqs.length;
      from = lowest - 1;
    }
    return result;
  }

  private async markVerified(chatId: number, lower: number, upper: number, failedSeqs: number[]): Promise<void> {
    if (upper <= lower) return;
    const failed = failedSeqs.length
      ? sql`int8multirange(${sql.join(
          failedSeqs.map((s) => sql`int8range(${s}, ${s + 1})`),
          sql`, `,
        )})`
      : sql`'{}'::int8multirange`;
    await this.db.execute(
      sql`update chats set verified_ranges = (verified_ranges + int8multirange(int8range(${lower}, ${upper}))) - ${failed}
           where id = ${chatId}`,
    );
  }

  async chat(chatId: number): Promise<HistoryChat | null> {
    const row = await maybeOne<{ id: number; qq_account_id: number; uin: number; scene: string; peer_id: number; uid: string | null }>(
      this.db,
      sql`select c.id, c.qq_account_id, q.uin, c.scene, c.peer_id, p.uid
            from chats c join qq_accounts q on q.id = c.qq_account_id
            left join peers p on p.qq_account_id = c.qq_account_id and p.peer_id = c.peer_id
                              and p.kind = case c.scene when 'group' then 'group' else 'user' end
           where c.id = ${chatId}`,
    );
    if (!row || (row.scene !== 'friend' && row.scene !== 'group')) return null;
    return {
      id: row.id,
      qqAccountId: row.qq_account_id,
      selfUin: Number(row.uin),
      scene: row.scene,
      peerId: Number(row.peer_id),
      ...(row.scene === 'friend' && row.uid ? { peerUid: row.uid } : {}),
    };
  }
}
