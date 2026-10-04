// 增量同步查询（docs/design.md 4.7）："版本化行"——每行记着最后一次变更时的序号，
// 差量就是"序号大于客户端游标"的行的最新状态。所有读取都在可重复读快照里完成。
import { sql } from 'drizzle-orm';
import { maybeOne, rows, type Db, type Queryable } from '../db/client.ts';
import {
  DIALOG_COLUMNS,
  CHAT_EVENT_COLUMNS,
  MESSAGE_COLUMNS,
  messageColumns,
  OUTBOX_COLUMNS,
  PEER_COLUMNS,
  sqlList,
  toChatEvent,
  toDialog,
  toMessage,
  toOutbox,
  toPeer,
  type ChatEventRow,
  type DialogRow,
  type MessageRow,
  type OutboxRow,
  type PeerRow,
  type TombstoneRow,
} from './rows.ts';

export class NotFoundError extends Error {}

const SNAPSHOT = { isolationLevel: 'repeatable read', accessMode: 'read only' } as const;

export interface Difference {
  /** 客户端应用本次结果后的新游标。 */
  pts: number;
  /** false 表示还有下一页，客户端应以新游标继续拉取。 */
  final: boolean;
  /** 游标早于墓碑保留范围，只能全量重拉会话列表。 */
  tooLong: boolean;
  dialogs: DialogRow[];
  peers: PeerRow[];
  tombstones: TombstoneRow[];
  /** 发件箱变化；全新同步（pts = 0）只包含尚未发送成功的条目。 */
  outbox: OutboxRow[];
}

export interface ChatDifference {
  chatPts: number;
  final: boolean;
  /** 变化太多：messages 换成最新一页，客户端应丢弃该会话的本地窗口。 */
  tooLong: boolean;
  messages: MessageRow[];
  /** 同一段 chat_pts 里变化的服务事件（与消息共用版本号）。 */
  events: ChatEventRow[];
}

export async function getState(db: Db, accountId: number): Promise<{ pts: number }> {
  const row = await maybeOne<{ pts: number }>(db, sql`select pts from sync_state where account_id = ${accountId}`);
  if (!row) throw new NotFoundError(`account ${accountId} not found`);
  return { pts: row.pts };
}

export async function getDifference(db: Db, accountId: number, fromPts: number, limit = 500): Promise<Difference> {
  return db.transaction(async (tx) => {
    const state = await maybeOne<{ pts: number; tombstone_horizon_pts: number }>(
      tx,
      sql`select pts, tombstone_horizon_pts from sync_state where account_id = ${accountId}`,
    );
    if (!state) throw new NotFoundError(`account ${accountId} not found`);
    const empty = { dialogs: [], peers: [], tombstones: [], outbox: [] };
    if (fromPts < state.tombstone_horizon_pts) return { pts: state.pts, final: true, tooLong: true, ...empty };
    if (fromPts >= state.pts) return { pts: state.pts, final: true, tooLong: false, ...empty };

    const changes = await rows<{ kind: string; k1: number | null; k2: string | null; k3: number | null; pts: number }>(
      tx,
      sql`
        select kind, k1, k2, k3, pts from (
          select 'dialog' as kind, c.id as k1, null::text as k2, null::bigint as k3, c.dialog_pts as pts
            from chats c join qq_accounts q on q.id = c.qq_account_id
           where q.account_id = ${accountId} and c.dialog_pts > ${fromPts}
          union all
          select 'peer', p.qq_account_id, p.kind, p.peer_id, p.pts
            from peers p join qq_accounts q on q.id = p.qq_account_id
           where q.account_id = ${accountId} and p.pts > ${fromPts}
          union all
          select 'tombstone', null, t.entity || ':' || t.entity_key, null, t.pts
            from tombstones t
           where t.account_id = ${accountId} and t.pts > ${fromPts}
          union all
          select 'outbox', o.id, null, null, o.pts
            from outbox o
           where o.account_id = ${accountId} and o.pts > ${fromPts}
             ${fromPts === 0 ? sql`and o.state <> 'sent'` : sql``}
        ) changes
        order by pts
        limit ${limit}`,
    );

    const partial = changes.length === limit;
    const newPts = partial ? changes[changes.length - 1]!.pts : state.pts;
    const chatIds = changes.filter((c) => c.kind === 'dialog').map((c) => c.k1!);
    const peerKeys = changes.filter((c) => c.kind === 'peer');
    const tombstones = changes
      .filter((c) => c.kind === 'tombstone')
      .map((c) => {
        const [entity, ...rest] = c.k2!.split(':');
        return { pts: c.pts, entity: entity!, key: rest.join(':') };
      });

    const outboxIds = changes.filter((c) => c.kind === 'outbox').map((c) => c.k1!);
    const outbox =
      outboxIds.length === 0
        ? []
        : (await rows(tx, sql`select ${OUTBOX_COLUMNS} from outbox where id in ${sqlList(outboxIds)} order by pts`)).map(toOutbox);
    const dialogs = await loadDialogs(tx, chatIds);
    const peers =
      peerKeys.length === 0
        ? []
        : (
            await rows(
              tx,
              sql`select ${PEER_COLUMNS} from peers
                   where (qq_account_id, kind, peer_id) in (${sql.join(
                     peerKeys.map((p) => sql`(${p.k1}, ${p.k2}, ${p.k3})`),
                     sql`, `,
                   )})`,
            )
          ).map(toPeer);
    return { pts: newPts, final: !partial, tooLong: false, dialogs, peers, tombstones, outbox };
  }, SNAPSHOT);
}

/** 按 id 读取会话，并附上顶部消息（会话列表的预览）。 */
export async function loadDialogs(db: Queryable, chatIds: readonly number[]): Promise<DialogRow[]> {
  if (chatIds.length === 0) return [];
  const chatRows = await rows(db, sql`select ${DIALOG_COLUMNS} from chats where id in ${sqlList(chatIds)}`);
  const tops = await rows(
    db,
    sql`select ${messageColumns('m')} from messages m join chats c on c.id = m.chat_id and m.seq = c.top_seq
         where c.id in ${sqlList(chatIds)}`,
  );
  const topByChat = new Map(tops.map((r) => [r.chat_id as number, toMessage(r)]));
  const byId = new Map(chatRows.map((r) => [r.id as number, toDialog(r, topByChat.get(r.id as number) ?? null)]));
  return chatIds.map((id) => byId.get(id)).filter((d): d is DialogRow => Boolean(d));
}


async function chatPtsFor(db: Queryable, accountId: number, chatId: number): Promise<number> {
  const row = await maybeOne<{ chat_pts: number }>(
    db,
    sql`select c.chat_pts from chats c join qq_accounts q on q.id = c.qq_account_id
         where c.id = ${chatId} and q.account_id = ${accountId}`,
  );
  if (!row) throw new NotFoundError(`chat ${chatId} not found`);
  return row.chat_pts;
}

export async function getChatDifference(
  db: Db,
  accountId: number,
  chatId: number,
  fromChatPts: number,
  limit = 200,
  tooLongThreshold = 1000,
): Promise<ChatDifference> {
  return db.transaction(async (tx) => {
    const current = await chatPtsFor(tx, accountId, chatId);
    return chatDifferenceAt(tx, chatId, current, fromChatPts, limit, tooLongThreshold);
  }, SNAPSHOT);
}

export const MAX_BATCH_CHATS = 100;

/**
 * 批量版本：一次往返补齐多个会话的"首屏"（预取用）。每个会话最多 perChatLimit 条；
 * 变化超过一屏时直接给最新一屏（tooLong）。不存在或不属于该账号的会话直接跳过。
 */
export async function getChatDifferences(
  db: Db,
  accountId: number,
  chats: readonly { chatId: number; chatPts: number }[],
  perChatLimit: number,
): Promise<(ChatDifference & { chatId: number })[]> {
  const wanted = new Map<number, number>();
  for (const c of chats.slice(0, MAX_BATCH_CHATS)) if (!wanted.has(c.chatId)) wanted.set(c.chatId, c.chatPts);
  if (wanted.size === 0) return [];
  return db.transaction(async (tx) => {
    const owned = await rows<{ id: number; chat_pts: number }>(
      tx,
      sql`select c.id, c.chat_pts from chats c join qq_accounts q on q.id = c.qq_account_id
           where q.account_id = ${accountId} and c.id in ${sqlList([...wanted.keys()])}`,
    );
    const currentById = new Map(owned.map((c) => [c.id, c.chat_pts]));
    const result: (ChatDifference & { chatId: number })[] = [];
    // 按客户端给的顺序返回（客户端已按优先级排好）。
    for (const [chatId, fromChatPts] of wanted) {
      const current = currentById.get(chatId);
      if (current === undefined) continue;
      const diff = await chatDifferenceAt(tx, chatId, current, fromChatPts, perChatLimit, perChatLimit);
      result.push({ chatId, ...diff });
    }
    return result;
  }, SNAPSHOT);
}

async function chatDifferenceAt(
  tx: Queryable,
  chatId: number,
  current: number,
  fromChatPts: number,
  limit: number,
  tooLongThreshold: number,
): Promise<ChatDifference> {
  if (fromChatPts >= current) return { chatPts: current, final: true, tooLong: false, messages: [], events: [] };

  const [{ n } = { n: 0 }] = await rows<{ n: number }>(
    tx,
    sql`select count(*)::int as n from (
          (select 1 from messages where chat_id = ${chatId} and version > ${fromChatPts} limit ${tooLongThreshold + 1})
          union all
          (select 1 from chat_events where chat_id = ${chatId} and version > ${fromChatPts} limit ${tooLongThreshold + 1})
        ) s`,
  );
  if (n > tooLongThreshold) {
    const latest = (
      await rows(tx, sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} order by seq desc limit ${limit}`)
    )
      .map(toMessage)
      .reverse();
    const since = latest[0]?.time ?? null;
    const events = (
      await rows(
        tx,
        sql`select ${CHAT_EVENT_COLUMNS} from chat_events
             where chat_id = ${chatId} ${since ? sql`and time >= ${since.toISOString()}::timestamptz` : sql``}
             order by time desc limit ${limit}`,
      )
    )
      .map(toChatEvent)
      .reverse();
    return { chatPts: current, final: true, tooLong: true, messages: latest, events };
  }

  // 消息与服务事件共用 chat_pts：按版本号合在一起分页。
  const changed = await rows<{ kind: string; k: number; version: number }>(
    tx,
    sql`select kind, k, version from (
          select 'm' as kind, seq as k, version from messages where chat_id = ${chatId} and version > ${fromChatPts}
          union all
          select 'e', id, version from chat_events where chat_id = ${chatId} and version > ${fromChatPts}
        ) changes
        order by version limit ${limit}`,
  );
  const partial = changed.length === limit;
  const seqs = changed.filter((c) => c.kind === 'm').map((c) => c.k);
  const eventIds = changed.filter((c) => c.kind === 'e').map((c) => c.k);
  const messages =
    seqs.length === 0
      ? []
      : (
          await rows(
            tx,
            sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} and seq in ${sqlList(seqs)} order by version`,
          )
        ).map(toMessage);
  const events =
    eventIds.length === 0
      ? []
      : (await rows(tx, sql`select ${CHAT_EVENT_COLUMNS} from chat_events where id in ${sqlList(eventIds)} order by version`)).map(
          toChatEvent,
        );
  return {
    chatPts: partial ? changed[changed.length - 1]!.version : current,
    final: !partial,
    tooLong: false,
    messages,
    events,
  };
}

export type HistoryDirection = 'older' | 'newer' | 'around';

/** 按 seq 翻页读取历史；返回的 chatPts 让客户端从这里开始跟进该会话的变化。 */
export async function getHistory(
  db: Db,
  accountId: number,
  chatId: number,
  opts: { anchorSeq?: number | null; direction: HistoryDirection; limit: number },
): Promise<{ chatPts: number; messages: MessageRow[]; events: ChatEventRow[] }> {
  return db.transaction(async (tx) => {
    const chatPts = await chatPtsFor(tx, accountId, chatId);
    const limit = Math.max(1, Math.min(opts.limit, 200));
    const anchor = opts.anchorSeq ?? null;
    let list: MessageRow[];
    if (anchor === null) {
      list = (
        await rows(tx, sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} order by seq desc limit ${limit}`)
      )
        .map(toMessage)
        .reverse();
    } else if (opts.direction === 'older') {
      list = (
        await rows(
          tx,
          sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} and seq < ${anchor} order by seq desc limit ${limit}`,
        )
      )
        .map(toMessage)
        .reverse();
    } else if (opts.direction === 'newer') {
      list = (
        await rows(
          tx,
          sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} and seq > ${anchor} order by seq asc limit ${limit}`,
        )
      ).map(toMessage);
    } else {
      // around：锚点（含）之前取一半，之后取另一半；用于"跳转到原消息"。
      const half = Math.ceil(limit / 2);
      const before = (
        await rows(
          tx,
          sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} and seq <= ${anchor} order by seq desc limit ${half}`,
        )
      )
        .map(toMessage)
        .reverse();
      const after = (
        await rows(
          tx,
          sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chatId} and seq > ${anchor} order by seq asc limit ${limit - before.length}`,
        )
      ).map(toMessage);
      list = [...before, ...after];
    }
    return { chatPts, messages: list, events: await eventsForPage(tx, chatId, list, anchor, opts.direction, limit) };
  }, SNAPSHOT);
}

/**
 * 一页历史对应的服务事件：落在这页消息时间范围内的；这页到了会话开头或结尾时，那一侧不设边界
 * （例如最新一页包含最后一条消息之后的入群、戳一戳）。时间相同的事件可能在相邻两页都出现，客户端按 id 去重。
 */
async function eventsForPage(
  tx: Queryable,
  chatId: number,
  list: MessageRow[],
  anchor: number | null,
  direction: HistoryDirection,
  limit: number,
): Promise<ChatEventRow[]> {
  const top = await maybeOne<{ top: number | null }>(tx, sql`select max(seq) as top from messages where chat_id = ${chatId}`);
  const first = list[0];
  const last = list[list.length - 1];
  const reachedStart = !first || (list.length < limit && direction !== 'newer');
  const reachedEnd = anchor === null || !last || last.seq >= (top?.top ?? 0);
  return (
    await rows(
      tx,
      sql`select ${CHAT_EVENT_COLUMNS} from chat_events
           where chat_id = ${chatId}
             ${reachedStart ? sql`` : sql`and time >= ${first!.time.toISOString()}::timestamptz`}
             ${reachedEnd ? sql`` : sql`and time <= ${last!.time.toISOString()}::timestamptz`}
           order by time, id limit 500`,
    )
  ).map(toChatEvent);
}

/** 会话列表：按顶部消息时间倒序分页（首次进入 App 时可以用它，增量更新走 getDifference）。 */
export async function listDialogs(
  db: Db,
  accountId: number,
  opts: { limit: number; beforeChatId?: number | null; beforeTopTime?: Date | null },
): Promise<{ pts: number; dialogs: DialogRow[] }> {
  return db.transaction(async (tx) => {
    const state = await maybeOne<{ pts: number }>(tx, sql`select pts from sync_state where account_id = ${accountId}`);
    if (!state) throw new NotFoundError(`account ${accountId} not found`);
    const limit = Math.max(1, Math.min(opts.limit, 200));
    const cursor =
      opts.beforeTopTime && opts.beforeChatId
        ? sql`and (coalesce(c.top_time, 'epoch'::timestamptz), c.id) < (${opts.beforeTopTime.toISOString()}::timestamptz, ${opts.beforeChatId})`
        : sql``;
    const ids = await rows<{ id: number }>(
      tx,
      sql`select c.id from chats c join qq_accounts q on q.id = c.qq_account_id
           where q.account_id = ${accountId} ${cursor}
           order by coalesce(c.top_time, 'epoch'::timestamptz) desc, c.id desc
           limit ${limit}`,
    );
    return { pts: state.pts, dialogs: await loadDialogs(tx, ids.map((r) => r.id)) };
  }, SNAPSHOT);
}
