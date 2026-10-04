// 全文搜索（docs/design.md 4.10）：PGroonga 索引在 messages.text 上（中文按 bigram 切分，撤回的消息也能搜到）。
// 按时间倒序、以 (time, chat_id, seq) 为游标分页；只返回本账号的会话。
import { sql } from 'drizzle-orm';
import { rows, toDate, type Db } from '../db/client.ts';
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
    // 查询语法有误（例如括号不配对）：按普通文本再搜一次。
    if (!/syntax|parse|query/i.test(String((error as Error)?.message ?? '') + String((error as { cause?: Error })?.cause?.message ?? ''))) throw error;
    const escaped = await rows<{ q: string }>(db, sql`select pgroonga_query_escape(${q}) as q`);
    return run(db, accountId, escaped[0]!.q, filters, page.before, limit);
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
  const found = await rows(
    db,
    sql`select ${messageColumns('m')}
          from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
         where ${sql.join(conditions, sql` and `)}
         order by m.time desc, m.chat_id desc, m.seq desc
         limit ${limit + 1}`,
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
