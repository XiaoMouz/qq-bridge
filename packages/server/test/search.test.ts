import { MessageFlag, type Segment } from '@qqbridge/domain';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { searchMessages, SearchQueryError } from '../src/search/messages.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, imageMessage, services, textMessage, type TestAccount } from './helpers/fixtures.ts';

let t: TestDb;
let acc: TestAccount;
let groupChat: number;
let friendChat: number;

beforeAll(async () => {
  t = await startTestDb();
  const { ingest } = services(t.db);
  acc = await createTestAccount(t.db, ingest);
  const other = await createTestAccount(t.db, ingest);
  const base = 1_700_000_000;
  const say = async (scene: 'group' | 'friend', peer: number, seq: number, sender: number, text: string, extra?: Segment[]) =>
    (await ingest.ingestMessage(acc.qqAccountId, textMessage(scene, peer, seq, sender, { text, time: base + seq * 60, ...(extra ? { extra } : {}) })))
      .chatId;
  groupChat = await say('group', 900001, 1, 20002, '今天天气不错，适合去爬山');
  await say('group', 900001, 2, 30003, '明天下雨，爬山取消');
  await say('group', 900001, 3, 20002, '周末一起吃火锅吗');
  friendChat = await say('friend', 30003, 4, 30003, '天气预报说周末晴天');
  await say('friend', 30003, 5, acc.uin, '那周末去爬山');
  await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 900001, 6, 20002, {}, { time: base + 6 * 60 }));
  for (let seq = 7; seq <= 31; seq++) await say('group', 900001, seq, 20002, `签到第${seq}天`);
  // 别人的账号里同样的词不应该被搜到。
  await ingest.ingestMessage(other.qqAccountId, textMessage('group', 900001, 1, 20002, { text: '今天天气不错' }));
});

afterAll(async () => {
  await t?.stop();
});

const seqs = (r: { messages: { seq: number }[] }) => r.messages.map((m) => m.seq);

describe('searchMessages', () => {
  it('finds Chinese words inside sentences, newest first, only in my chats', async () => {
    const r = await searchMessages(t.db, acc.accountId, '天气');
    expect(seqs(r)).toEqual([4, 1]);
    expect(r.keywords).toEqual(['天气']);
    expect(r.messages[0]!.chatId).toBe(friendChat);
  });

  it('supports AND / OR / NOT, and falls back to plain text when the syntax is broken', async () => {
    expect(seqs(await searchMessages(t.db, acc.accountId, '爬山 周末'))).toEqual([5]);
    expect(seqs(await searchMessages(t.db, acc.accountId, '火锅 OR 下雨'))).toEqual([3, 2]);
    expect(seqs(await searchMessages(t.db, acc.accountId, '爬山 -取消'))).toEqual([5, 1]);
    expect(seqs(await searchMessages(t.db, acc.accountId, '(爬山'))).toEqual([]);
    await expect(searchMessages(t.db, acc.accountId, '   ')).rejects.toBeInstanceOf(SearchQueryError);
  });

  it('filters by chat, sender, content type and time', async () => {
    expect(seqs(await searchMessages(t.db, acc.accountId, '爬山', { chatId: groupChat }))).toEqual([2, 1]);
    expect(seqs(await searchMessages(t.db, acc.accountId, '爬山', { senderId: acc.uin }))).toEqual([5]);
    expect(seqs(await searchMessages(t.db, acc.accountId, '图片', { flagsAny: MessageFlag.photo }))).toEqual([6]);
    const base = 1_700_000_000;
    expect(
      seqs(await searchMessages(t.db, acc.accountId, '爬山', { since: new Date((base + 2 * 60) * 1000), until: new Date((base + 5 * 60) * 1000) })),
    ).toEqual([2]);
  });

  it('pages with a cursor without gaps or duplicates', async () => {
    const all: number[] = [];
    let before;
    for (let page = 0; page < 10; page++) {
      const r = await searchMessages(t.db, acc.accountId, '签到', {}, { limit: 10, ...(before ? { before } : {}) });
      all.push(...seqs(r));
      if (!r.next) break;
      before = r.next;
    }
    expect(all).toEqual(Array.from({ length: 25 }, (_, i) => 31 - i));
  });
});
