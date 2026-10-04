// 组装上游相关的部件：接入点（hub）→ 收件箱（inbox）→ 入库；连上后对账预热（reconciler），之后补缺口（history）；媒体换链接（mediaSource）。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { IngestService } from '../ingest/service.ts';
import { UpstreamHub } from './hub.ts';
import { InboxProcessor, type InboxOptions } from './inbox.ts';
import { NapcatMediaSource } from './napcat/media-source.ts';
import { Reconciler } from './reconcile.ts';
import { HoleFiller } from './history.ts';
import type { ActiveChats } from '../sync/active-chats.ts';

export interface UpstreamConfig {
  token: string;
  account?: string | undefined;
  warmMessages: number;
  backfillIntervalMs: number;
  inboxRetentionDays: number;
}

export function createUpstream(
  db: Db,
  ingest: IngestService,
  logger: Logger,
  config: UpstreamConfig,
  hooks: {
    onMediaQueued?: () => void;
    activeChats?: Pick<ActiveChats, 'chatIds'>;
    onCall?: InboxOptions['onCall'];
  } = {},
) {
  const log = logger.child({ component: 'upstream' });
  const hub = new UpstreamHub(db, ingest, { token: config.token, resolveAccount: () => resolveAccount(db, config.account), logger: log });
  const inbox = new InboxProcessor(db, ingest, {
    logger: log,
    ...(hooks.onMediaQueued ? { onMediaQueued: hooks.onMediaQueued } : {}),
    ...(hooks.onCall ? { onCall: hooks.onCall } : {}),
  });
  const history = new HoleFiller(db, hub, inbox, hooks.activeChats ?? null, {
    requestIntervalMs: config.backfillIntervalMs,
    logger: log,
  });
  const reconciler = new Reconciler(db, hub, inbox, history, {
    warmMessages: config.warmMessages,
    logger: log,
    onFinished: (qqAccountId) => history.schedule(qqAccountId),
  });
  const mediaSource = new NapcatMediaSource(db, hub);
  hub.onEvents = (qqAccountId) => inbox.poke(qqAccountId);
  hub.onConnected = (info) => reconciler.schedule(info.qqAccountId);

  const timers: NodeJS.Timeout[] = [];
  let lastLogged = 0;
  return {
    hub,
    inbox,
    reconciler,
    history,
    mediaSource,
    async start() {
      // 上次退出时没处理完的事件。
      const pending = await rows<{ qq_account_id: number }>(
        db,
        sql`select distinct qq_account_id from upstream_events where state = 'pending'`,
      );
      for (const p of pending) inbox.poke(p.qq_account_id);
      timers.push(
        setInterval(() => {
          if (inbox.latency.recorded === lastLogged) return;
          lastLogged = inbox.latency.recorded;
          log.info({ latency: inbox.latency.summary() }, 'upstream realtime latency (ms)');
        }, 60_000),
        setInterval(
          () => void inbox.prune(config.inboxRetentionDays).catch((error: unknown) => log.warn({ err: error }, 'inbox prune failed')),
          24 * 3600_000,
        ),
      );
      for (const t of timers) t.unref();
      history.start(async () => (await rows<{ id: number }>(db, sql`select id from qq_accounts`)).map((r) => r.id));
    },
    async stop() {
      for (const t of timers) clearInterval(t);
      history.stop();
      hub.close();
      await inbox.idle();
    },
  };
}

export type Upstream = ReturnType<typeof createUpstream>;

/** QQ 号归属的服务端账号：配置了用户名就用它；否则要求恰好只有一个账号（个人自用）。 */
async function resolveAccount(db: Db, username: string | undefined): Promise<number> {
  if (username) {
    const row = await maybeOne<{ id: number }>(db, sql`select id from accounts where username = ${username}`);
    if (!row) throw new Error(`UPSTREAM_ACCOUNT ${username} does not exist`);
    return row.id;
  }
  const list = await rows<{ id: number }>(db, sql`select id from accounts order by id limit 2`);
  if (list.length !== 1) throw new Error('set UPSTREAM_ACCOUNT: the QQ account owner is ambiguous (need exactly one account)');
  return list[0]!.id;
}
