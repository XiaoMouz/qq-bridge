import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one, rows } from '../src/db/client.ts';
import { HoleFiller } from '../src/upstream/history.ts';
import { InboxProcessor } from '../src/upstream/inbox.ts';
import { Reconciler } from '../src/upstream/reconcile.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage, type TestAccount } from './helpers/fixtures.ts';
import { FakeQq } from './helpers/fake-qq.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

async function chatState(acc: TestAccount, peerId: number) {
  return one<{ id: number; unread_count: number; top_seq: number; n: number; min_seq: number }>(
    t.db,
    sql`select c.id, c.unread_count, c.top_seq, count(m.seq)::int as n, min(m.seq)::int as min_seq
          from chats c join messages m on m.chat_id = c.id
         where c.qq_account_id = ${acc.qqAccountId} and c.peer_id = ${peerId}
         group by c.id`,
  );
}

describe('Reconciler', () => {
  it('warms up chats the server has never seen and fills gaps in the ones it has, politely', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(2, '700001', 500, () => '20002'); // 新会话：预热最新 45 条
    qq.chat(1, '30010', 50, (seq) => (seq <= 45 ? String(acc.uin) : '30010')); // 已有 1..45，断线期间对方发了 46..50
    qq.chat(2, '700003', 3, () => '20002'); // 已是最新
    for (let seq = 1; seq <= 45; seq++) {
      await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 30010, seq, acc.uin, { self: true }));
    }
    for (let seq = 1; seq <= 3; seq++) await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 700003, seq, 20002));

    const sleeps: number[] = [];
    const inbox = new InboxProcessor(t.db, ingest);
    const sleep = async (ms: number) => void sleeps.push(ms);
    const history = new HoleFiller(t.db, qq, inbox, null, { pageSize: 20, requestIntervalMs: 1000, sleep });
    const reconciler = new Reconciler(t.db, qq, inbox, history, { warmMessages: 45, sleep });
    const report = await reconciler.run(acc.qqAccountId);

    expect(report).toEqual({ contacts: 3, warmedChats: 1, gapFilledChats: 1, messages: 50, errors: 0 });
    const warmed = await chatState(acc, 700001);
    expect(warmed).toMatchObject({ n: 45, min_seq: 456, top_seq: 500, unread_count: 0 }); // 预热的历史不算未读
    const filled = await chatState(acc, 30010);
    expect(filled).toMatchObject({ n: 50, min_seq: 1, top_seq: 50, unread_count: 5 }); // 断线期间漏掉的算未读
    expect(await chatState(acc, 700003)).toMatchObject({ n: 3 });

    const calls = qq.calls.filter((c) => c.action === 'x.history');
    expect(calls.map((c) => [c.params.peerUin, c.params.fromSeq, c.params.count])).toEqual([
      ['700001', '499', 20],
      ['700001', '479', 20],
      ['700001', '459', 4],
      ['30010', '49', 4],
    ]);
    expect(sleeps).toHaveLength(4); // 每次拉历史之前都限速
    expect(sleeps.every((ms) => ms >= 1000 && ms <= 1500)).toBe(true);

    // 再跑一次：都已是最新，不再拉历史。
    const again = await reconciler.run(acc.qqAccountId);
    expect(again).toMatchObject({ warmedChats: 0, gapFilledChats: 0, messages: 0 });
    expect(qq.calls.filter((c) => c.action === 'x.history')).toHaveLength(4);
  });

  it('caps gap filling per chat and leaves the rest as a hole for the hole filler', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(2, '700010', 1000, () => '20002');
    for (let seq = 1; seq <= 10; seq++) await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 700010, seq, acc.uin, { self: true }));

    const inbox = new InboxProcessor(t.db, ingest);
    const history = new HoleFiller(t.db, qq, inbox, null, { sleep: async () => {} });
    const reconciler = new Reconciler(t.db, qq, inbox, history, { maxGapFill: 30, sleep: async () => {} });
    expect(await reconciler.run(acc.qqAccountId)).toMatchObject({ gapFilledChats: 1, messages: 30 });
    const seqs = await rows<{ seq: number }>(
      t.db,
      sql`select m.seq from messages m join chats c on c.id = m.chat_id where c.peer_id = 700010 and m.seq > 10 order by m.seq`,
    );
    expect(seqs.map((r) => r.seq)).toEqual(Array.from({ length: 30 }, (_, i) => 971 + i));
  });
});
