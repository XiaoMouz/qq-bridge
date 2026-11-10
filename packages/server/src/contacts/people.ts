// 只有号码的人（群事件的操作人 / 对象、灰条里的人、合并转发的发送者）：补上名字。
// - 本地有的（群成员表、peers）直接用；
// - 没有的向 QQ 要一次 get_stranger_info，存进 peers（经 pts 同步给客户端，客户端查名字和打开资料都用它）；
// - 要不到的记进 people_lookups，一周内不再要。
// 所有请求排成一队、两次之间至少隔 minIntervalMs（ContactService 的说明：逐个爬资料风控风险高），
// 收到事件时要的人排在回填前面。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { rows, type Db, type Tx } from '../db/client.ts';
import { stripNul } from '../db/nul.ts';
import type { IngestService } from '../ingest/service.ts';
import type { UpstreamHub } from '../upstream/hub.ts';

export interface PeopleOptions {
  /** 两次向 QQ 要资料之间至少隔多久。 */
  minIntervalMs?: number;
  /** 要不到的多久之后再试。 */
  retryFailedMs?: number;
  logger?: Logger;
  sleep?: (ms: number) => Promise<void>;
}

/**
 * QQ 合并转发里隐藏了发送者的节点：号码一律是 1094950020、名字「QQ用户」（2026-11-10 库里 21 万个节点都是这样，
 * 同一条记录里被回复的人在回复元素里是真号码）。这不是一个真人，不补名字、不当成能打开资料的人。
 */
export const ANONYMOUS_FORWARD_SENDER = 1094950020;

type Job = { qqAccountId: number; userId: number; done: Array<() => void> };

export class PeopleResolver {
  private readonly o: Required<Omit<PeopleOptions, 'logger'>> & Pick<PeopleOptions, 'logger'>;
  /** 收到事件时要的（先处理）和回填的（后处理）。 */
  private readonly urgent: Job[] = [];
  private readonly background: Job[] = [];
  private readonly pending = new Map<string, Job>();
  private running = false;
  private lastAt = 0;
  private backfillTimer: NodeJS.Timeout | null = null;
  private stopped = false;

  constructor(
    private readonly db: Db,
    private readonly ingest: Pick<IngestService, 'upsertPeer'>,
    private readonly upstream: () => Pick<UpstreamHub, 'call' | 'isConnected'> | null,
    opts: PeopleOptions = {},
  ) {
    this.o = {
      minIntervalMs: 1500,
      retryFailedMs: 7 * 24 * 3600_000,
      sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      ...opts,
    };
  }

  /**
   * 收到事件时：本地没有名字的人向 QQ 要，最多等 timeoutMs（要不到也不挡入库，之后到了照样存进 peers）。
   */
  async ensure(qqAccountId: number, groupId: number | null, userIds: readonly (number | undefined | null)[], timeoutMs = 3000): Promise<void> {
    const missing = await this.missing(qqAccountId, groupId, userIds);
    if (!missing.length) return;
    const waits = missing.map((id) => new Promise<void>((resolve) => this.enqueue(qqAccountId, id, true, resolve)));
    let timer: NodeJS.Timeout | undefined;
    await Promise.race([Promise.all(waits), new Promise<void>((resolve) => (timer = setTimeout(resolve, timeoutMs)))]);
    clearTimeout(timer);
  }

  /** 本地没有名字、也没在最近要过的人。 */
  async missing(qqAccountId: number, groupId: number | null, userIds: readonly (number | undefined | null)[]): Promise<number[]> {
    const ids = [...new Set(userIds.filter((id): id is number => typeof id === 'number' && id > 10000 && id !== ANONYMOUS_FORWARD_SENDER))];
    if (!ids.length) return [];
    const known = await rows<{ id: string }>(
      this.db,
      sql`select peer_id as id from peers
           where qq_account_id = ${qqAccountId} and kind = 'user' and peer_id = any(${bigints(ids)}) and coalesce(name, '') <> ''
          union
          select user_id from group_members
           where qq_account_id = ${qqAccountId} and group_id = ${groupId ?? 0} and user_id = any(${bigints(ids)})
             and coalesce(nullif(card, ''), nickname, '') <> ''
          union
          select user_id from people_lookups
           where qq_account_id = ${qqAccountId} and user_id = any(${bigints(ids)})
             and (found or tried_at > now() - make_interval(secs => ${this.o.retryFailedMs / 1000}))`,
    );
    const have = new Set(known.map((r) => Number(r.id)));
    return ids.filter((id) => !have.has(id));
  }

  /**
   * 回填已存档的：群事件里只有号码的人、合并转发里名字是号码的发送者。上游连上后慢慢要（每个间隔 minIntervalMs），
   * 已经要过的不再要，可以反复跑。
   */
  startBackfill(accounts: () => Promise<number[]>, delayMs = 2 * 60_000): void {
    if (this.backfillTimer) return;
    this.backfillTimer = setTimeout(() => {
      void (async () => {
        for (const qq of await accounts()) {
          if (this.stopped) return;
          const ids = await this.backfillCandidates(qq);
          this.o.logger?.info({ qqAccountId: qq, count: ids.length }, 'people backfill queued');
          for (const id of ids) this.enqueue(qq, id, false);
        }
      })().catch((error: unknown) => this.o.logger?.warn({ err: error }, 'people backfill failed'));
    }, delayMs);
    this.backfillTimer.unref();
  }

  stop(): void {
    this.stopped = true;
    if (this.backfillTimer) clearTimeout(this.backfillTimer);
    this.urgent.length = 0;
    this.background.length = 0;
  }

  /** 回填的人：最近出现的排前面。 */
  async backfillCandidates(qqAccountId: number): Promise<number[]> {
    const found = await rows<{ id: string }>(
      this.db,
      sql`with seen as (
            select x.id, max(e.time) as last, c.scene, c.peer_id
              from chat_events e join chats c on c.id = e.chat_id,
                   lateral (values (e.actor_id), (e.target_id)) x(id)
             where c.qq_account_id = ${qqAccountId} and x.id > 10000
             group by x.id, c.scene, c.peer_id
            union all
            select (n->>'senderId')::bigint, to_timestamp((n->>'time')::bigint), c.scene, c.peer_id
              from forward_bundles f join chats c on c.id = f.chat_id, jsonb_array_elements(f.nodes) n
             where c.qq_account_id = ${qqAccountId} and n->>'senderName' ~ '^[0-9]+$'
          )
          select s.id from seen s
           where s.id <> ${ANONYMOUS_FORWARD_SENDER}
             and not exists (select 1 from peers p where p.qq_account_id = ${qqAccountId} and p.kind = 'user' and p.peer_id = s.id and coalesce(p.name, '') <> '')
             and not (s.scene = 'group' and exists (select 1 from group_members m where m.qq_account_id = ${qqAccountId} and m.group_id = s.peer_id and m.user_id = s.id))
             and not exists (select 1 from people_lookups l where l.qq_account_id = ${qqAccountId} and l.user_id = s.id
                               and (l.found or l.tried_at > now() - make_interval(secs => ${this.o.retryFailedMs / 1000})))
           group by s.id order by max(s.last) desc`,
    );
    return found.map((r) => Number(r.id));
  }

  private enqueue(qqAccountId: number, userId: number, urgent: boolean, done?: () => void): void {
    const key = `${qqAccountId}:${userId}`;
    const existing = this.pending.get(key);
    if (existing) {
      if (done) existing.done.push(done);
      // 回填排着的人这会儿收到事件了：挪到前面。
      const i = urgent ? this.background.indexOf(existing) : -1;
      if (i >= 0) {
        this.background.splice(i, 1);
        this.urgent.push(existing);
      }
      return;
    }
    const job: Job = { qqAccountId, userId, done: done ? [done] : [] };
    this.pending.set(key, job);
    (urgent ? this.urgent : this.background).push(job);
    void this.run();
  }

  private async run(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      for (;;) {
        const job = this.urgent.shift() ?? this.background.shift();
        if (!job || this.stopped) break;
        const wait = this.lastAt + this.o.minIntervalMs - Date.now();
        if (wait > 0) await this.o.sleep(wait);
        try {
          await this.fetch(job.qqAccountId, job.userId);
        } catch (error) {
          this.o.logger?.debug({ err: error, userId: job.userId }, 'people lookup failed');
        } finally {
          this.lastAt = Date.now();
          this.pending.delete(`${job.qqAccountId}:${job.userId}`);
          for (const done of job.done) done();
        }
      }
    } finally {
      this.running = false;
    }
  }

  private async fetch(qqAccountId: number, userId: number): Promise<void> {
    const hub = this.upstream();
    // 离线时不记失败：下次连上再要。
    if (!hub?.isConnected(qqAccountId)) return;
    const info = await hub
      .call<Record<string, unknown> | null>(qqAccountId, 'ob11', { name: 'get_stranger_info', params: { user_id: String(userId), no_cache: false } }, 15_000)
      .catch(() => null);
    const name = typeof info?.nickname === 'string' ? stripNul(info.nickname).trim() : '';
    if (name) {
      await this.ingest.upsertPeer(qqAccountId, {
        kind: 'user',
        peerId: userId,
        name,
        ...(typeof info?.uid === 'string' && info.uid ? { uid: info.uid } : {}),
      });
    }
    await this.db.execute(
      sql`insert into people_lookups (qq_account_id, user_id, found) values (${qqAccountId}, ${userId}, ${Boolean(name)})
          on conflict (qq_account_id, user_id) do update set found = excluded.found, tried_at = now()`,
    );
  }
}

/**
 * 本地能查到的显示名（群里：群名片 > 备注 > 群昵称 > 昵称；私聊：备注 > 昵称）。
 * 入库时写进群事件的 data.names，客户端没有这个人的资料时也能显示当时的名字。
 */
export async function localNames(tx: Db | Tx, qqAccountId: number, groupId: number | null, userIds: readonly (number | undefined | null)[]): Promise<Map<number, string>> {
  const ids = [...new Set(userIds.filter((id): id is number => typeof id === 'number' && id > 0))];
  const out = new Map<number, string>();
  if (!ids.length) return out;
  const found = await rows<{ id: string; name: string | null }>(
    tx,
    groupId
      ? sql`select u.id, coalesce(nullif(m.card, ''), nullif(p.remark, ''), nullif(m.nickname, ''), nullif(p.name, '')) as name
              from unnest(${bigints(ids)}) u(id)
              left join group_members m on m.qq_account_id = ${qqAccountId} and m.group_id = ${groupId} and m.user_id = u.id
              left join peers p on p.qq_account_id = ${qqAccountId} and p.kind = 'user' and p.peer_id = u.id`
      : sql`select peer_id as id, coalesce(nullif(remark, ''), nullif(name, '')) as name from peers
             where qq_account_id = ${qqAccountId} and kind = 'user' and peer_id = any(${bigints(ids)})`,
  );
  for (const r of found) if (r.name) out.set(Number(r.id), r.name);
  return out;
}

function bigints(list: readonly number[]) {
  return sql`array[${sql.join(list.map((v) => sql`${v}`), sql`, `)}]::bigint[]`;
}
