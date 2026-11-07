// 存储页「消息」一类：有结果就先给、过期在后台重算（2026-10-24）；统计查询同时只跑一份、带超时（2026-11-04）。
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { SharedResults, withStatementTimeout } from '../src/db/shared.ts';
import { rows } from '../src/db/client.ts';
import { sql } from 'drizzle-orm';
import { StorageBrowser } from '../src/media/storage-browse.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});
afterEach(() => {
  vi.useRealTimers();
});

describe('storage browser message usage', () => {
  it('serves the last result at once and refreshes stale results in the background', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 920001, 1, 20002));
    const browser = new StorageBrowser(t.db);
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-10-24T08:00:00Z'));

    const count = async () => (await browser.chats(acc.accountId, ['message'])).find((c) => c.chatId === chatId)?.count;
    expect(await count()).toBe(1);

    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 920001, 2, 20002));
    // 1 小时内：直接用上次的结果。
    expect(await count()).toBe(1);

    // 过期：先给旧结果，同时在后台重算；算完再问就是新的。
    vi.setSystemTime(new Date('2026-10-24T09:01:00Z'));
    expect(await count()).toBe(1);
    await (browser as unknown as { shared: SharedResults }).shared.idle();
    expect(await count()).toBe(2);
  });

});

describe('storage items sort and senders', () => {
  it('sorts by size or time and filters / groups by sender', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 930001, 1, 20002));
    const add = async (n: number, size: number, sender: number, time: string) => {
      const sha = n.toString(16).padStart(64, 'a');
      await t.db.execute(sql`insert into blobs (sha256, md5, md5_head, size, storage_key, kind) values (${sha}, ${sha.slice(0, 32)}, ${sha.slice(0, 32)}, ${size}, ${sha}, 'image')`);
      await t.db.execute(sql`insert into media_refs (chat_id, message_seq, role, kind, sha256, sender_uin, time, fetch_state)
                             values (${chatId}, ${n}, 'attachment', 'image', ${sha}, ${sender}, ${time}::timestamptz, 'stored')`);
      return sha;
    };
    const a = await add(1, 300, 20002, '2026-01-01T00:00:00Z');
    const b = await add(2, 100, 30003, '2026-03-01T00:00:00Z');
    const c = await add(3, 200, 20002, '2026-02-01T00:00:00Z');
    const browser = new StorageBrowser(t.db);
    const shas = async (q: Parameters<StorageBrowser['items']>[5]) => (await browser.items(acc.accountId, chatId, ['image'], 0, 10, q)).map((i) => i.sha256);
    expect(await shas({})).toEqual([a, c, b]);
    expect(await shas({ sort: 'time_desc' })).toEqual([b, c, a]);
    expect(await shas({ sort: 'time_asc' })).toEqual([a, c, b]);
    expect(await shas({ senderIds: [20002] })).toEqual([a, c]);
    expect(await shas({ excludeSenderIds: [20002] })).toEqual([b]);
    expect((await browser.items(acc.accountId, chatId, ['image'], 0, 10))[0]!.senderId).toBe(20002);
    const senders = await browser.senders(acc.accountId, chatId, ['image']);
    expect(senders.map((s) => [s.senderId, s.count, s.bytes])).toEqual([[20002, 2, 500], [30003, 1, 100]]);
  });
});

describe('shared stats queries', () => {
  it('runs one query for concurrent identical requests', async () => {
    const shared = new SharedResults();
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const fn = async () => {
      calls++;
      await gate;
      return calls;
    };
    const all = Promise.all([shared.run('k', fn), shared.run('k', fn), shared.run('k', fn)]);
    release();
    expect(await all).toEqual([1, 1, 1]);
    expect(calls).toBe(1);
    // 没设缓存：跑完后再问会重新算。
    expect(await shared.run('k', fn)).toBe(2);
  });

  it('cancels statements that exceed the timeout', async () => {
    const err = await withStatementTimeout(t.db, 50, (tx) => rows(tx, sql`select pg_sleep(1)`)).catch((e: unknown) => e);
    expect((err as { cause?: { code?: string } }).cause?.code).toBe('57014');
  });
});
