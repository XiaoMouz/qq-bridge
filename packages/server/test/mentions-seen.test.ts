// 看过的 @我 / 回复我 / @全体成员：不再算未读 @，也不再出现在"有人@我"里；已读位置和未读数不动。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('markMentionsSeen', () => {
  it('clears seen mentions from the mention counts but keeps the read position and unread count', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const at = [{ type: 'mention' as const, userId: acc.uin }];
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 900, 1, 901, { extra: at }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 900, 2, 901, { extra: [{ type: 'mention_all' }] }));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 900, 3, 901));
    const state = () =>
      one<{ unread_count: number; unread_mentions: number; unread_mention_all: number; read_inbox_max_seq: number }>(
        t.db,
        sql`select unread_count, unread_mentions, unread_mention_all, read_inbox_max_seq from chats where id = ${chatId}`,
      );
    expect(await state()).toMatchObject({ unread_count: 3, unread_mentions: 1, unread_mention_all: 1 });

    expect(await ingest.markMentionsSeen(acc.accountId, chatId, [1, 3])).toBe(true); // 3 不是 @，忽略
    expect(await state()).toMatchObject({ unread_count: 3, unread_mentions: 0, unread_mention_all: 1, read_inbox_max_seq: 0 });
    expect(await ingest.markMentionsSeen(acc.accountId, chatId, [1])).toBe(false);
    await expect(ingest.markMentionsSeen(acc.accountId + 999, chatId, [2])).rejects.toThrow();
  });
});
