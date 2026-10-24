// 存储页「消息」一类：扫整张消息表很慢，有结果就先给、过期在后台重算（2026-10-24）。
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
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
    // 5 分钟内：直接用上次的结果。
    expect(await count()).toBe(1);

    // 过期：先给旧结果，同时在后台重算；算完再问就是新的。
    vi.setSystemTime(new Date('2026-10-24T08:06:00Z'));
    expect(await count()).toBe(1);
    await (browser as unknown as { messageRefresh: Map<number, Promise<unknown>> }).messageRefresh.get(acc.accountId);
    expect(await count()).toBe(2);
  });
});
