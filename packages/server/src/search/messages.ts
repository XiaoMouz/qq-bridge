// 全文搜索（docs/design.md 4.10）：PGroonga 索引在 messages.text 上（中文按 bigram 切分，撤回的消息也能搜到）。
// 按时间倒序、以 (time, chat_id, seq) 为游标分页；只返回本账号的会话。
import { sql } from 'drizzle-orm';
import { rows, toDate, type Db } from '../db/client.ts';
import { withStatementTimeout } from '../db/shared.ts';
import { messageColumns, toMessage, type MessageRow } from '../sync/rows.ts';

export interface SearchFilters {
  chatId?: number;
  senderId?: number;
  /** 只看这些人（和 senderId 合并）。 */
  senderIds?: number[];
  excludeSenderIds?: number[];
  /** 只搜这些会话（和 chatId 合并）。 */
  chatIds?: number[];
  excludeChatIds?: number[];
  oldestFirst?: boolean;
  /** MessageFlag 位的"或"。 */
  flagsAny?: number;
  since?: Date;
  until?: Date;
}

export interface SearchCursor {
  time: Date;
  chatId: number;
  seq: number;
}

export interface SearchResult {
  messages: MessageRow[];
  keywords: string[];
  next: SearchCursor | null;
}

export class SearchQueryError extends Error {}
/** 搜索超过 SEARCH_TIMEOUT_MS 被数据库取消（多半是很常见的单字）。 */
export class SearchTimeoutError extends Error {}

// 2026-11-04 实测：消息表 1100 万行，PGroonga 先在整张表里取命中再按会话过滤，单字「的」全表命中 150 万行，
// 只搜一个会话冷缓存也要 6 秒；没有上限时客户端放弃了查询还在跑，和存储页的全表统计叠在一起把数据库拖垮。
const SEARCH_TIMEOUT_MS = 15_000;
const MAX_KEYWORDLESS_CHATS = 20;
const MAX_LIST = 200;

const ids = (list: number[] | undefined) => [...new Set((list ?? []).filter((v) => Number.isSafeInteger(v) && v !== 0))].slice(0, MAX_LIST);

function chatList(f: SearchFilters): number[] {
  return ids([...(f.chatId ? [f.chatId] : []), ...(f.chatIds ?? [])]);
}

export async function searchMessages(
  db: Db,
  accountId: number,
  query: string,
  filters: SearchFilters = {},
  page: { before?: SearchCursor; limit?: number } = {},
): Promise<SearchResult> {
  const q = query.trim();
  // 没有关键词时只能在指定的几个会话里按其他条件筛：走 (chat_id, time) 索引，不扫全表。
  const chats = chatList(filters);
  if (!q && (chats.length === 0 || chats.length > MAX_KEYWORDLESS_CHATS)) throw new SearchQueryError('query is empty');
  if (q.length > 200) throw new SearchQueryError('query is too long');
  const limit = Math.max(1, Math.min(page.limit ?? 30, 100));
  if (!q) {
    try {
      return await run(db, accountId, null, filters, page.before, limit);
    } catch (error) {
      if ((error as { cause?: { code?: string } })?.cause?.code === '57014') throw new SearchTimeoutError('search timed out');
      throw error;
    }
  }
  try {
    return await run(db, accountId, q, filters, page.before, limit);
  } catch (error) {
    // 只看数据库自己的报错：drizzle 包装后的 message 以「Failed query:」开头，原来按 /query/ 匹配会让
    // 任何错误（包括超时）都再整查一遍。
    const cause = (error as { cause?: { code?: string; message?: string } })?.cause;
    if (cause?.code === '57014') throw new SearchTimeoutError('search timed out');
    // 查询语法有误（例如括号不配对）：按普通文本再搜一次。
    if (!/syntax/i.test(cause?.message ?? '')) throw error;
    const escaped = await rows<{ q: string }>(db, sql`select pgroonga_query_escape(${q}) as q`);
    try {
      return await run(db, accountId, escaped[0]!.q, filters, page.before, limit);
    } catch (retry) {
      if ((retry as { cause?: { code?: string } })?.cause?.code === '57014') throw new SearchTimeoutError('search timed out');
      throw retry;
    }
  }
}

async function run(db: Db, accountId: number, q: string | null, f: SearchFilters, before: SearchCursor | undefined, limit: number) {
  const chats = chatList(f);
  const senders = ids([...(f.senderId ? [f.senderId] : []), ...(f.senderIds ?? [])]);
  const excludeSenders = ids(f.excludeSenderIds);
  const excludeChats = ids(f.excludeChatIds);
  const bigints = (list: number[]) => sql`array[${sql.join(list.map((v) => sql`${v}`), sql`, `)}]::bigint[]`;
  const asc = f.oldestFirst === true;
  const conditions = [
    sql`q.account_id = ${accountId}`,
    ...(q !== null ? [sql`m.text &@~ ${q}`] : []),
    ...(chats.length ? [sql`m.chat_id = any(${bigints(chats)})`] : []),
    ...(excludeChats.length ? [sql`m.chat_id <> all(${bigints(excludeChats)})`] : []),
    ...(senders.length ? [sql`m.sender_uin = any(${bigints(senders)})`] : []),
    ...(excludeSenders.length ? [sql`m.sender_uin <> all(${bigints(excludeSenders)})`] : []),
    ...(f.flagsAny ? [sql`(m.flags & ${f.flagsAny}) <> 0`] : []),
    ...(f.since ? [sql`m.time >= ${f.since.toISOString()}::timestamptz`] : []),
    ...(f.until ? [sql`m.time < ${f.until.toISOString()}::timestamptz`] : []),
    ...(before
      ? [
          asc
            ? sql`(m.time, m.chat_id, m.seq) > (${before.time.toISOString()}::timestamptz, ${before.chatId}, ${before.seq})`
            : sql`(m.time, m.chat_id, m.seq) < (${before.time.toISOString()}::timestamptz, ${before.chatId}, ${before.seq})`,
        ]
      : []),
  ];
  const order = asc ? sql`m.time asc, m.chat_id asc, m.seq asc` : sql`m.time desc, m.chat_id desc, m.seq desc`;
  const found = await withStatementTimeout(db, SEARCH_TIMEOUT_MS, (tx) =>
    rows(
      tx,
      sql`select ${messageColumns('m')}
            from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
           where ${sql.join(conditions, sql` and `)}
           order by ${order}
           limit ${limit + 1}`,
    ),
  );
  const more = found.length > limit;
  const messages = found.slice(0, limit).map(toMessage);
  const last = messages[messages.length - 1];
  const keywords = q === null ? [] : ((await rows<{ k: string[] | null }>(db, sql`select pgroonga_query_extract_keywords(${q}) as k`))[0]?.k ?? []);
  return {
    messages,
    keywords,
    next: more && last ? { time: toDate(last.time)!, chatId: last.chatId, seq: last.seq } : null,
  };
}
