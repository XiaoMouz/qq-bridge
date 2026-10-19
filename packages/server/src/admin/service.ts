// 管理（AdminService）：系统状态汇总、存档完整性与深度归档。QQ 扫码登录中转见 napcat-webui.ts。
import type { Scene } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, type Db } from '../db/client.ts';
import type { CallRecord, CallService } from '../calls/service.ts';
import type { MediaService } from '../media/service.ts';
import type { HoleFiller } from '../upstream/history.ts';
import type { UpstreamHub } from '../upstream/hub.ts';

export interface SystemStatus {
  qq: {
    qqAccountId: number;
    uin: number;
    nickname: string;
    connected: boolean;
    connectedAt: Date | null;
    pluginVersion: string;
    lastEventAt: Date | null;
  }[];
  inbox: { pending: number; failed: number; ignored24h: number };
  archive: { chatsWithHoles: number; missingSeqs: number; deepArchiveChats: number };
  media: { pending: number; failed: number; expired: number };
  outbox: { pending: number; failed: number };
  calls: {
    configured: boolean;
    bridgeEnabled: boolean;
    engineLoggedIn: boolean;
    pausedReason: string;
    lastError: string;
    gatewayReachable: boolean;
    gatewayRoom: string;
    activeCall: CallRecord | null;
  };
  storage: { hotBytes: number; coldBytes: number; coldTierEnabled: boolean };
  serverStartedAt: Date;
}

export interface ChatArchive {
  chatId: number;
  scene: Scene;
  peerId: number;
  name: string;
  earliestSeq: number;
  topSeq: number;
  holes: number;
  missingSeqs: number;
  deepArchive: boolean;
  historyComplete: boolean;
}

const startedAt = new Date();

export class AdminService {
  private readonly statusQueries = new Map<number, Promise<SystemStatus>>();
  constructor(
    private readonly db: Db,
    private readonly deps: {
      upstream: () => Pick<UpstreamHub, 'call' | 'isConnected' | 'connections'> | null;
      history: () => Pick<HoleFiller, 'holes' | 'schedule'> | null;
      calls: () => Pick<CallService, 'configured' | 'gatewayStatus' | 'active'>;
      media: Pick<MediaService, 'storageOverview' | 'hasColdTier'>;
    },
  ) {}

  async status(accountId: number): Promise<SystemStatus> {
    // 客户端重试尚未返回的状态请求时，共享本轮统计，避免挤占消息入库连接。
    let pending = this.statusQueries.get(accountId);
    if (!pending) {
      pending = this.queryStatus(accountId).finally(() => this.statusQueries.delete(accountId));
      this.statusQueries.set(accountId, pending);
    }
    return pending;
  }

  private async queryStatus(accountId: number): Promise<SystemStatus> {
    const accounts = await rows<{ id: number; uin: number; nickname: string | null }>(
      this.db,
      sql`select id, uin, nickname from qq_accounts where account_id = ${accountId} order by id`,
    );
    const ids = accounts.map((a) => Number(a.id));
    const idList = ids.length ? sql.join(ids.map((i) => sql`${i}`), sql`, `) : sql`null`;
    const hub = this.deps.upstream();
    const conns = new Map((hub?.connections() ?? []).map((c) => [c.qqAccountId, c]));
    const lastEvents = new Map(
      (
        await rows<{ qq_account_id: number; at: Date | string }>(
          this.db,
          // 按账号从时间索引取一条，避免状态页每次刷新都扫描全部历史事件。
          sql`select q.id as qq_account_id, e.received_at as at
                from qq_accounts q cross join lateral (
                  select received_at from upstream_events where qq_account_id = q.id
                   order by received_at desc limit 1
                ) e
               where q.account_id = ${accountId}`,
        )
      ).map((r) => [Number(r.qq_account_id), new Date(r.at)]),
    );
    const inbox = await one<{ pending: number; failed: number; ignored: number }>(
      this.db,
      sql`select count(*) filter (where state = 'pending')::int as pending, count(*) filter (where state = 'failed')::int as failed,
                 count(*) filter (where state = 'ignored' and received_at > now() - interval '24 hours')::int as ignored
            from upstream_events where qq_account_id in (${idList})
             and state in ('pending', 'failed', 'ignored')
             and (state <> 'ignored' or received_at > now() - interval '24 hours')`,
    );
    const media = await one<{ pending: number; failed: number; expired: number }>(
      this.db,
      sql`select count(*) filter (where r.fetch_state = 'pending')::int as pending, count(*) filter (where r.fetch_state = 'failed')::int as failed,
                 count(*) filter (where r.fetch_state = 'expired')::int as expired
            from media_refs r join chats c on c.id = r.chat_id where c.qq_account_id in (${idList})`,
    );
    const outbox = await one<{ pending: number; failed: number }>(
      this.db,
      sql`select count(*) filter (where state in ('pending', 'sending'))::int as pending, count(*) filter (where state = 'failed')::int as failed
            from outbox where account_id = ${accountId}`,
    );
    let chatsWithHoles = 0;
    let missingSeqs = 0;
    const history = this.deps.history();
    for (const id of ids) {
      const holes = (await history?.holes(id)) ?? [];
      chatsWithHoles += new Set(holes.filter((h) => !h.deep).map((h) => h.chatId)).size;
      missingSeqs += holes.filter((h) => !h.deep).reduce((n, h) => n + (h.upper - h.lower), 0);
    }
    const deep = await one<{ n: number }>(this.db, sql`select count(*)::int as n from chats where qq_account_id in (${idList}) and deep_archive_at is not null`);

    // 通话桥：插件里的状态要问插件（QQ 离线时拿不到）。
    const calls = this.deps.calls();
    let bridge: Record<string, unknown> = {};
    const first = ids.find((id) => hub?.isConnected(id));
    if (hub && first !== undefined) {
      bridge = await hub.call<Record<string, unknown>>(first, 'x.call.status', {}, 5000).catch(() => ({}));
    }
    const stats = (bridge.stats ?? {}) as { lastError?: string | null };
    const gateway = await calls.gatewayStatus();
    const overview = await this.deps.media.storageOverview(accountId, 0);

    return {
      qq: accounts.map((a) => {
        const conn = conns.get(Number(a.id));
        return {
          qqAccountId: Number(a.id),
          uin: Number(a.uin),
          nickname: a.nickname ?? '',
          connected: Boolean(conn),
          connectedAt: conn?.connectedAt ?? null,
          pluginVersion: conn?.pluginVersion ?? '',
          lastEventAt: lastEvents.get(Number(a.id)) ?? null,
        };
      }),
      inbox: { pending: inbox.pending, failed: inbox.failed, ignored24h: inbox.ignored },
      archive: { chatsWithHoles, missingSeqs, deepArchiveChats: deep.n },
      media,
      outbox,
      calls: {
        configured: calls.configured,
        bridgeEnabled: bridge.enabled === true,
        engineLoggedIn: bridge.loginPosted === true,
        pausedReason: typeof bridge.reloginPaused === 'string' ? bridge.reloginPaused : '',
        lastError: typeof stats.lastError === 'string' ? stats.lastError : '',
        gatewayReachable: gateway.reachable,
        gatewayRoom: gateway.room ?? '',
        activeCall: await calls.active(accountId),
      },
      storage: { hotBytes: overview.hotBytes, coldBytes: overview.coldBytes, coldTierEnabled: this.deps.media.hasColdTier },
      serverStartedAt: startedAt,
    };
  }

  /** 各会话的存档完整性，缺口多的在前。 */
  async archiveStatus(accountId: number, limit: number): Promise<ChatArchive[]> {
    const chats = await rows<{
      id: number;
      qq_account_id: number;
      scene: Scene;
      peer_id: number;
      name: string | null;
      lo: number | null;
      hi: number | null;
      deep: boolean;
      complete: boolean;
    }>(
      this.db,
      sql`select c.id, c.qq_account_id, c.scene, c.peer_id, coalesce(nullif(p.remark, ''), p.name) as name,
                 (select min(seq) from messages m where m.chat_id = c.id) as lo, c.top_seq as hi,
                 c.deep_archive_at is not null as deep,
                 c.verified_ranges @> int8range(1, greatest(2, (select min(seq) from messages m where m.chat_id = c.id))) as complete
            from chats c join qq_accounts q on q.id = c.qq_account_id
            left join peers p on p.qq_account_id = c.qq_account_id and p.peer_id = c.peer_id
                             and p.kind = case c.scene when 'group' then 'group' else 'user' end
           where q.account_id = ${accountId} and c.scene in ('friend', 'group')`,
    );
    const holesByChat = new Map<number, { holes: number; missing: number }>();
    const history = this.deps.history();
    for (const qq of new Set(chats.map((c) => Number(c.qq_account_id)))) {
      for (const h of (await history?.holes(qq)) ?? []) {
        if (h.deep) continue;
        const e = holesByChat.get(h.chatId) ?? { holes: 0, missing: 0 };
        e.holes += 1;
        e.missing += h.upper - h.lower;
        holesByChat.set(h.chatId, e);
      }
    }
    return chats
      .map((c) => {
        const h = holesByChat.get(Number(c.id)) ?? { holes: 0, missing: 0 };
        return {
          chatId: Number(c.id),
          scene: c.scene,
          peerId: Number(c.peer_id),
          name: c.name ?? '',
          earliestSeq: Number(c.lo ?? 0),
          topSeq: Number(c.hi ?? 0),
          holes: h.holes,
          missingSeqs: h.missing,
          deepArchive: c.deep,
          historyComplete: Boolean(c.complete),
        };
      })
      .sort((a, b) => b.missingSeqs - a.missingSeqs || Number(b.deepArchive) - Number(a.deepArchive) || b.topSeq - a.topSeq)
      .slice(0, limit);
  }

  async setDeepArchive(accountId: number, chatId: number, enabled: boolean): Promise<boolean> {
    const row = await maybeOne<{ qq_account_id: number }>(
      this.db,
      sql`update chats c set deep_archive_at = ${enabled ? sql`coalesce(c.deep_archive_at, now())` : sql`null`}
            from qq_accounts q
           where q.id = c.qq_account_id and c.id = ${chatId} and q.account_id = ${accountId}
          returning c.qq_account_id`,
    );
    if (!row) return false;
    if (enabled) this.deps.history()?.schedule(Number(row.qq_account_id));
    return true;
  }

  async fillHolesNow(accountId: number): Promise<void> {
    const ids = await rows<{ id: number }>(this.db, sql`select id from qq_accounts where account_id = ${accountId}`);
    for (const { id } of ids) this.deps.history()?.schedule(Number(id));
  }
}
