// 全文搜索（docs/design.md 4.10）：PGroonga 索引在 messages.text 上（中文按 bigram 切分，撤回的消息也能搜到）。
// 按时间倒序、以 (time, chat_id, seq) 为游标分页；只返回本账号的会话。
import { sql } from 'drizzle-orm';
import { rows, toDate, type Db } from '../db/client.ts';
import { withStatementTimeout } from '../db/shared.ts';
import { messageColumns, toMessage, type MessageRow } from '../sync/rows.ts';

export interface SearchFilters {
  chatId?: number;
  senderId?: number;
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

export async function searchMessages(
  db: Db,
  accountId: number,
  query: string,
  filters: SearchFilters = {},
  page: { before?: SearchCursor; limit?: number } = {},
): Promise<SearchResult> {
  const q = query.trim();
  if (!q) throw new SearchQueryError('query is empty');
  if (q.length > 200) throw new SearchQueryError('query is too long');
  const limit = Math.max(1, Math.min(page.limit ?? 30, 100));
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

async function run(db: Db, accountId: number, q: string, f: SearchFilters, before: SearchCursor | undefined, limit: number) {
  const conditions = [
    sql`q.account_id = ${accountId}`,
    sql`m.text &@~ ${q}`,
    ...(f.chatId ? [sql`m.chat_id = ${f.chatId}`] : []),
    ...(f.senderId ? [sql`m.sender_uin = ${f.senderId}`] : []),
    ...(f.flagsAny ? [sql`(m.flags & ${f.flagsAny}) <> 0`] : []),
    ...(f.since ? [sql`m.time >= ${f.since.toISOString()}::timestamptz`] : []),
    ...(f.until ? [sql`m.time < ${f.until.toISOString()}::timestamptz`] : []),
    ...(before ? [sql`(m.time, m.chat_id, m.seq) < (${before.time.toISOString()}::timestamptz, ${before.chatId}, ${before.seq})`] : []),
  ];
  const found = await withStatementTimeout(db, SEARCH_TIMEOUT_MS, (tx) =>
    rows(
      tx,
      sql`select ${messageColumns('m')}
            from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
           where ${sql.join(conditions, sql` and `)}
           order by m.time desc, m.chat_id desc, m.seq desc
           limit ${limit + 1}`,
    ),
  );
  const more = found.length > limit;
  const messages = found.slice(0, limit).map(toMessage);
  const last = messages[messages.length - 1];
  const keywords = await rows<{ k: string[] | null }>(db, sql`select pgroonga_query_extract_keywords(${q}) as k`);
  return {
    messages,
    keywords: keywords[0]?.k ?? [],
    next: more && last ? { time: toDate(last.time)!, chatId: last.chatId, seq: last.seq } : null,
  };
}
