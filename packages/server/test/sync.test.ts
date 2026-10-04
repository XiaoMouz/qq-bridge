import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { getChatDifference, getChatDifferences, getDifference, getHistory, getState } from '../src/sync/difference.ts';
import { subscribe, type StreamEvent } from '../src/sync/subscribe.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('ingest + difference', () => {
  it('creates a dialog on the first realtime message with exactly one unread', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const res = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 500, 41, 7));
    expect(res.inserted).toBe(true);

    const diff = await getDifference(t.db, acc.accountId, 0);
    expect(diff.final).toBe(true);
    expect(diff.dialogs).toHaveLength(1);
    expect(diff.dialogs[0]).toMatchObject({ scene: 'group', peerId: 500, topSeq: 41, unreadCount: 1, readInboxMaxSeq: 40 });
    expect(diff.dialogs[0]?.topMessage?.text).toBe('msg 41');

    const chatDiff = await getChatDifference(t.db, acc.accountId, res.chatId, 0);
    expect(chatDiff.messages.map((m) => m.seq)).toEqual([41]);
    expect(chatDiff.chatPts).toBe(1);
  });

  it('ignores duplicates without allocating sequence numbers', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 9, 1, 9));
    const before = await getState(t.db, acc.accountId);
    const again = await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 9, 1, 9));
    expect(again.inserted).toBe(false);
    expect(await getState(t.db, acc.accountId)).toEqual(before);
  });

  it('treats a message sent from another device as reading the chat up to it', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 1, 10, 7));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 1, 11, 8, { extra: [{ type: 'mention', userId: acc.uin }] }));
    let [dialog] = (await getDifference(t.db, acc.accountId, 0)).dialogs;
    expect(dialog).toMatchObject({ unreadCount: 2, unreadMentions: 1 });

    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 1, 12, acc.uin, { self: true, source: 'self' }));
    [dialog] = (await getDifference(t.db, acc.accountId, 0)).dialogs;
    expect(dialog).toMatchObject({ unreadCount: 0, unreadMentions: 0, readInboxMaxSeq: 12, topSeq: 12 });
  });

  it('keeps recalled content, bumps the version and fixes the unread count', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 3, 5, 3, { text: '秘密' }));
    expect(await ingest.recall(acc.qqAccountId, 'friend', 3, 5, 3, 1_800_000_100)).toBe(true);
    const diff = await getChatDifference(t.db, acc.accountId, chatId, 1);
    expect(diff.messages).toHaveLength(1);
    expect(diff.messages[0]).toMatchObject({ seq: 5, state: 'recalled', text: '秘密', recalledBy: 3, version: 2 });
    const [dialog] = (await getDifference(t.db, acc.accountId, 0)).dialogs;
    expect(dialog?.unreadCount).toBe(0);
    expect(await ingest.recall(acc.qqAccountId, 'friend', 3, 5, 3, 1_800_000_101)).toBe(false);
  });

  it('pages history around an anchor for jump-to-message', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    let chatId = 0;
    for (let seq = 1; seq <= 30; seq++) chatId = (await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 2, seq, 5))).chatId;
    const around = await getHistory(t.db, acc.accountId, chatId, { anchorSeq: 15, direction: 'around', limit: 6 });
    expect(around.messages.map((m) => m.seq)).toEqual([13, 14, 15, 16, 17, 18]);
    const older = await getHistory(t.db, acc.accountId, chatId, { anchorSeq: 5, direction: 'older', limit: 10 });
    expect(older.messages.map((m) => m.seq)).toEqual([1, 2, 3, 4]);
    const latest = await getHistory(t.db, acc.accountId, chatId, { direction: 'older', limit: 3 });
    expect(latest.messages.map((m) => m.seq)).toEqual([28, 29, 30]);
    expect(latest.chatPts).toBe(30);
  });

  it('pages the difference by pts and reports the cursor of each page', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    for (let peer = 1; peer <= 5; peer++) await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', peer, 1, peer));
    const first = await getDifference(t.db, acc.accountId, 0, 2);
    expect(first.final).toBe(false);
    expect(first.dialogs.map((d) => d.peerId)).toEqual([1, 2]);
    const second = await getDifference(t.db, acc.accountId, first.pts, 2);
    expect(second.dialogs.map((d) => d.peerId)).toEqual([3, 4]);
    const third = await getDifference(t.db, acc.accountId, second.pts, 2);
    expect(third.final).toBe(true);
    expect(third.dialogs.map((d) => d.peerId)).toEqual([5]);
    expect(third.pts).toBe((await getState(t.db, acc.accountId)).pts);
  });

  it('only emits peer updates when the profile actually changes', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    expect(await ingest.upsertPeer(acc.qqAccountId, { kind: 'group', peerId: 77, name: '摸鱼群' })).toBe(true);
    expect(await ingest.upsertPeer(acc.qqAccountId, { kind: 'group', peerId: 77, name: '摸鱼群' })).toBe(false);
    expect(await ingest.upsertPeer(acc.qqAccountId, { kind: 'group', peerId: 77, memberCount: 42 })).toBe(true);
    const diff = await getDifference(t.db, acc.accountId, 0);
    expect(diff.peers).toEqual([expect.objectContaining({ peerId: 77, name: '摸鱼群', memberCount: 42 })]);
  });
});

describe('batched chat differences (prefetch)', () => {
  it('returns the first screen of many chats in one call, in the client order, skipping foreign chats', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const other = await createTestAccount(t.db, ingest);
    // fresh：本地还没有；behind：本地落后两条；busy：本地落后很多（超过一屏）；same：已经最新。
    const fresh = (await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 801, 1, 5))).chatId;
    for (let seq = 2; seq <= 3; seq++) await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 801, seq, 5));
    const behind = (await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 802, 1, 802))).chatId;
    const behindPts = (await getChatDifference(t.db, acc.accountId, behind, 0)).chatPts;
    for (let seq = 2; seq <= 3; seq++) await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 802, seq, 802));
    const busy = (await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 803, 1, 6))).chatId;
    for (let seq = 2; seq <= 12; seq++) await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 803, seq, 6));
    const same = (await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 804, 1, 6))).chatId;
    const samePts = (await getChatDifference(t.db, acc.accountId, same, 0)).chatPts;
    const foreign = (await ingest.ingestMessage(other.qqAccountId, textMessage('group', 805, 1, 6))).chatId;

    const result = await getChatDifferences(
      t.db,
      acc.accountId,
      [
        { chatId: busy, chatPts: 1 },
        { chatId: foreign, chatPts: 0 },
        { chatId: fresh, chatPts: 0 },
        { chatId: behind, chatPts: behindPts },
        { chatId: same, chatPts: samePts },
        { chatId: fresh, chatPts: 0 }, // 重复的只算一次
      ],
      5,
    );
    expect(result.map((r) => r.chatId)).toEqual([busy, fresh, behind, same]);
    const byId = new Map(result.map((r) => [r.chatId, r]));
    // 变化超过一屏：直接给最新一屏，并告诉客户端中间可能有空洞。
    expect(byId.get(busy)).toMatchObject({ tooLong: true, final: true, chatPts: 12 });
    expect(byId.get(busy)!.messages.map((m) => m.seq)).toEqual([8, 9, 10, 11, 12]);
    expect(byId.get(fresh)).toMatchObject({ tooLong: false, final: true, chatPts: 3 });
    expect(byId.get(fresh)!.messages.map((m) => m.seq)).toEqual([1, 2, 3]);
    expect(byId.get(behind)!.messages.map((m) => m.seq)).toEqual([2, 3]);
    expect(byId.get(same)).toMatchObject({ messages: [], final: true, chatPts: samePts });

    // 与逐个调用 GetChatDifference 的结果一致。
    expect(byId.get(behind)).toMatchObject(await getChatDifference(t.db, acc.accountId, behind, behindPts, 5, 5));
    expect(await getChatDifferences(t.db, acc.accountId, [], 5)).toEqual([]);
  });
});

describe('subscribe', () => {
  it('replays the difference first, then streams live updates without duplicates', async () => {
    const { ingest, bus } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 1, 1, 1));

    const controller = new AbortController();
    const events: StreamEvent[] = [];
    const stream = subscribe(t.db, bus, acc.accountId, 0, controller.signal, { heartbeatMs: 50 });
    const consumer = (async () => {
      for await (const event of stream) {
        events.push(event);
        if (event.kind === 'update' && event.update.type === 'dialog' && event.update.dialog.topSeq === 2) controller.abort();
      }
    })();

    await new Promise((resolve) => setTimeout(resolve, 100));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 1, 2, 1));
    await consumer;

    expect(events[0]?.kind).toBe('difference');
    const live = events.filter((e) => e.kind === 'update');
    expect(live.map((e) => (e.kind === 'update' ? e.update.type : ''))).toEqual(['chatMessage', 'dialog']);
    const finalPts = (await one<{ pts: number }>(t.db, sql`select pts from sync_state where account_id = ${acc.accountId}`)).pts;
    const lastDialog = live[1];
    expect(lastDialog?.kind === 'update' && lastDialog.update.type === 'dialog' && lastDialog.update.pts).toBe(finalPts);
    expect(bus.listenerCount(acc.accountId)).toBe(0);
  });
});
