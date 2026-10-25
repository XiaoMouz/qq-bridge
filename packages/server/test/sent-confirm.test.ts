// 发出去但 QQ 没推回来的消息：过了宽限期单独要一次，只要一次。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { SentConfirmer } from '../src/outbox/confirm.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('SentConfirmer', () => {
  it('fetches a sent message that never arrived once the grace period is over, and only once', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 900100, 10, 1));
    const insert = (seq: number, ago: string) =>
      t.db.execute(sql`insert into outbox (account_id, chat_id, client_random_id, content, state, result_seq, pts, updated_at)
                       values (${acc.accountId}, ${chatId}, ${seq}, '{"segments":[]}'::jsonb, 'sent', ${seq}, 0, now() - ${ago}::interval)`);
    await insert(11, '30 seconds'); // 早该到了
    await insert(12, '2 seconds'); // 还在宽限期里
    await insert(10, '30 seconds'); // 已经入库

    const asked: number[] = [];
    const confirmer = new SentConfirmer(t.db, () => ({
      ensureMessage: async (_chatId, seq) => {
        asked.push(seq);
        return true;
      },
    }));
    expect(await confirmer.runOnce()).toBe(1);
    expect(asked).toEqual([11]);
    await confirmer.runOnce();
    expect(asked).toEqual([11]);
    expect((await one<{ n: number }>(t.db, sql`select count(*)::int as n from outbox where chat_id = ${chatId}`)).n).toBe(3);
  });
});
