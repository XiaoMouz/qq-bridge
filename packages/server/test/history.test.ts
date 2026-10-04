// 存档完整性：缺口检测与补齐、QQ 上本来就没有的 seq、单条失败不影响其他消息、懒回填。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one, rows } from '../src/db/client.ts';
import { stripNul } from '../src/db/nul.ts';
import { HoleFiller } from '../src/upstream/history.ts';
import { InboxProcessor } from '../src/upstream/inbox.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { FakeQq } from './helpers/fake-qq.ts';
import { createTestAccount, services, textMessage, type TestAccount } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

const noSleep = async () => {};

async function seqs(acc: TestAccount, peerId: number): Promise<number[]> {
  const list = await rows<{ seq: number }>(
    t.db,
    sql`select m.seq from messages m join chats c on c.id = m.chat_id where c.qq_account_id = ${acc.qqAccountId} and c.peer_id = ${peerId} order by m.seq`,
  );
  return list.map((r) => Number(r.seq));
}

async function chatId(acc: TestAccount, peerId: number): Promise<number> {
  return (await one<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId} and peer_id = ${peerId}`)).id;
}

const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
const historyCalls = (qq: FakeQq) => qq.calls.filter((c) => c.action === 'x.history');

describe('HoleFiller', () => {
  it('finds holes between archived messages and fills them, newest first, then stays quiet', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    // QQ 上 41–45 本来就没有（删除等），补齐后也应算核对过、不再反复请求。
    qq.chat(2, '810001', 100, () => '20002', (seq) => seq >= 41 && seq <= 45);
    for (const seq of [...range(1, 10), ...range(50, 60), 100]) {
      await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 810001, seq, 20002));
    }
    const filler = new HoleFiller(t.db, qq, new InboxProcessor(t.db, ingest), null, { pageSize: 20, sleep: noSleep });
    const id = await chatId(acc, 810001);
    expect(await filler.holes(acc.qqAccountId)).toEqual([
      { chatId: id, lower: 11, upper: 50 },
      { chatId: id, lower: 61, upper: 100 },
    ]);

    const report = await filler.fillHoles(acc.qqAccountId);
    expect(report).toMatchObject({ holes: 2, failed: 0, remaining: 0 });
    expect(await seqs(acc, 810001)).toEqual(range(1, 100).filter((s) => s < 41 || s > 45));
    expect(await filler.holes(acc.qqAccountId)).toEqual([]);
    // 新缺口先补：第一次请求从 99 开始。
    expect(historyCalls(qq)[0]?.params).toMatchObject({ fromSeq: '99', count: 20 });

    const calls = historyCalls(qq).length;
    expect(await filler.fillHoles(acc.qqAccountId)).toMatchObject({ holes: 0, requests: 0 });
    expect(historyCalls(qq)).toHaveLength(calls);
  });

  it('skips a message that fails to store and retries only that one next time', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(2, '810002', 30, () => '20002');
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 810002, 1, 20002));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 810002, 30, 20002));

    const inbox = new InboxProcessor(t.db, ingest);
    let broken = true;
    const flaky: Pick<InboxProcessor, 'applyAction'> = {
      applyAction: async (qqAccountId, action) =>
        broken && action.type === 'message' && action.message.seq === 17 ? { state: 'failed', error: 'boom' } : inbox.applyAction(qqAccountId, action),
    };
    const filler = new HoleFiller(t.db, qq, flaky, null, { sleep: noSleep });
    expect(await filler.fillHoles(acc.qqAccountId)).toMatchObject({ failed: 1 });
    expect(await seqs(acc, 810002)).toEqual(range(1, 30).filter((s) => s !== 17));
    const id = await chatId(acc, 810002);
    expect(await filler.holes(acc.qqAccountId)).toEqual([{ chatId: id, lower: 17, upper: 18 }]);

    broken = false;
    await filler.fillHoles(acc.qqAccountId);
    expect(await seqs(acc, 810002)).toEqual(range(1, 30));
    expect(historyCalls(qq).at(-1)?.params).toMatchObject({ fromSeq: '17', count: 1 });
  });

  it('backfills older history on demand until QQ has nothing more', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(1, '30020', 100, () => '30020');
    for (const seq of range(91, 100)) await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 30020, seq, 30020));
    const filler = new HoleFiller(t.db, qq, new InboxProcessor(t.db, ingest), null, { pageSize: 50, sleep: noSleep });
    const id = await chatId(acc, 30020);

    expect(await filler.backfillOlder(id, 91, 30)).toBe(30);
    expect(await seqs(acc, 30020)).toEqual(range(61, 100));
    expect(await filler.backfillOlder(id, 61, 100)).toBe(60); // 拿到 1–60，再拉一次得到空页：到头了
    expect(await seqs(acc, 30020)).toEqual(range(1, 100));
    const calls = historyCalls(qq).length;
    expect(await filler.backfillOlder(id, 1, 50)).toBe(0);
    expect(await filler.backfillOlder(id, 30, 50)).toBe(0); // 已确认到头，不再问 QQ
    expect(historyCalls(qq)).toHaveLength(calls);
  });

  it('starts with the chat the user is looking at', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(2, '810003', 50, () => '20002');
    qq.chat(2, '810004', 500, () => '20002');
    for (const [peer, top] of [
      [810003, 50],
      [810004, 500],
    ] as const) {
      await ingest.ingestMessage(acc.qqAccountId, textMessage('group', peer, 1, 20002));
      await ingest.ingestMessage(acc.qqAccountId, textMessage('group', peer, top, 20002));
    }
    const active = await chatId(acc, 810003);
    const filler = new HoleFiller(t.db, qq, new InboxProcessor(t.db, ingest), { chatIds: () => [active] }, { sleep: noSleep, maxRequests: 1 });
    expect(await filler.fillHoles(acc.qqAccountId)).toMatchObject({ requests: 1, remaining: 1 });
    expect(historyCalls(qq)[0]?.params.peerUin).toBe('810003');
  });

  it('stores messages carrying NUL characters (PostgreSQL rejects them) with the NULs removed', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const msg = { ...textMessage('group', 810005, 1, 20002, { text: 'a\u0000b' }), raw: { card: { 'k\u0000': ['x\u0000y', 1] } } };
    await ingest.ingestMessage(acc.qqAccountId, msg);
    const stored = await one<{ text: string; raw: unknown; segments: unknown }>(
      t.db,
      sql`select m.text, m.raw, m.segments from messages m join chats c on c.id = m.chat_id where c.qq_account_id = ${acc.qqAccountId} and c.peer_id = 810005`,
    );
    expect(stored.text).toBe('ab');
    expect(stored.raw).toEqual({ card: { k: ['xy', 1] } });
    const clean = { a: [1, 'b'] };
    expect(stripNul(clean)).toBe(clean); // 没有 NUL 时不复制
  });

  it("treats QQ's 'no more messages' as the beginning of history and keeps going when one chat fails", async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq(acc.uin);
    qq.chat(2, '810006', 20, () => '20002');
    qq.chat(2, '810007', 20, () => '20002');
    for (const peer of [810006, 810007]) {
      await ingest.ingestMessage(acc.qqAccountId, textMessage('group', peer, 1, 20002));
      await ingest.ingestMessage(acc.qqAccountId, textMessage('group', peer, 20, 20002));
    }
    const hub = {
      call: async <T,>(qqId: number, action: string, params: any): Promise<T> => {
        if (params.peerUin === '810006') throw new Error('x.history: peer is gone');
        if (params.peerUin === '810007' && Number(params.fromSeq) < 10) return { result: 2004000, errMsg: 'no any more msg!', messages: [] } as T;
        return qq.call<T>(qqId, action, params);
      },
    };
    const filler = new HoleFiller(t.db, hub, new InboxProcessor(t.db, ingest), null, { pageSize: 5, sleep: noSleep });
    const report = await filler.fillHoles(acc.qqAccountId);
    expect(report).toMatchObject({ chatErrors: 1 });
    expect(await seqs(acc, 810007)).toEqual([1, ...range(10, 20)]);
    const left = await filler.holes(acc.qqAccountId);
    expect(left.map((h) => h.chatId)).toEqual([await chatId(acc, 810006)]); // 810007 的 2–9：QQ 说没有了，记为核对过
  });
});
