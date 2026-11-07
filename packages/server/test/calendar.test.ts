// 聊天日历：按当地日期、小时计数；跳到某个时刻（2026-11-08）。
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ChatCalendar } from '../src/sync/calendar.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('chat calendar', () => {
  it('counts messages per local day and hour and finds the message at a time', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const other = await createTestAccount(t.db, ingest);
    // 2026-03-01 23:30 UTC = 北京时间 3 月 2 日 07:30。
    const at = (iso: string) => Math.floor(Date.parse(iso) / 1000);
    const say = async (seq: number, iso: string) =>
      (await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 940001, seq, 20002, { time: at(iso) }))).chatId;
    const chatId = await say(1, '2026-03-01T10:00:00Z');
    await say(2, '2026-03-01T10:20:00Z');
    await say(3, '2026-03-01T23:30:00Z');
    const calendar = new ChatCalendar(t.db);
    const days = await calendar.days(acc.accountId, chatId, 480);
    expect(days.map((d) => [d.day, d.count])).toEqual([
      [at('2026-03-01T00:00:00+08:00'), 2],
      [at('2026-03-02T00:00:00+08:00'), 1],
    ]);
    expect(days[0]!.hours[18]).toBe(2);
    expect(days[1]!.hours[7]).toBe(1);
    expect((await calendar.days(acc.accountId, chatId, 0)).map((d) => d.count)).toEqual([3]);

    expect((await calendar.messageAt(acc.accountId, chatId, new Date('2026-03-01T10:10:00Z')))?.seq).toBe(2);
    expect((await calendar.messageAt(acc.accountId, chatId, new Date('2027-01-01T00:00:00Z')))?.seq).toBe(3);
    await expect(calendar.days(other.accountId, chatId, 480)).rejects.toThrow();
  });
});
