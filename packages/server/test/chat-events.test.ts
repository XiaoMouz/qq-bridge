// 服务事件（小灰条）、表情回应、"正在输入"：入库、同步、历史，以及收件箱重新处理。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { chatEventToProto, messageToProto } from '../src/api/convert.ts';
import { one, rows } from '../src/db/client.ts';
import { getChatDifference, getHistory } from '../src/sync/difference.ts';
import { subscribe, type StreamEvent } from '../src/sync/subscribe.ts';
import { InboxProcessor } from '../src/upstream/inbox.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';
import { el, messageEvent, raw } from './helpers/napcat.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('chat events', () => {
  it('stores service events once, interleaves them with messages by chat_pts and time', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const base = 1_700_000_000;
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 910001, 1, 20002, { time: base + 10 }));
    const join = { scene: 'group' as const, peerId: 910001, kind: 'member_join' as const, time: base + 20, actorId: 30003, targetId: 40004, data: { via: 'invite' } };
    expect(await ingest.addChatEvent(acc.qqAccountId, join, 1001)).toEqual({ inserted: true, chatId });
    expect(await ingest.addChatEvent(acc.qqAccountId, join, 1001)).toEqual({ inserted: false, chatId }); // 重新处理同一上游事件
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 910001, 2, 20002, { time: base + 30 }));
    await ingest.addChatEvent(acc.qqAccountId, {
      scene: 'group',
      peerId: 910001,
      kind: 'group_name',
      time: base + 40,
      actorId: 30003,
      data: { name: '新群名' },
      peers: [{ kind: 'group', peerId: 910001, name: '新群名' }],
    });

    // 差量：消息与事件按版本号合在一起，顺序与发生顺序一致。
    const diff = await getChatDifference(t.db, acc.accountId, chatId, 0);
    const order = [...diff.messages.map((m) => ({ v: m.version, x: `m${m.seq}` })), ...diff.events.map((e) => ({ v: e.version, x: e.kind }))]
      .sort((a, b) => a.v - b.v)
      .map((i) => i.x);
    expect(order).toEqual(['m1', 'member_join', 'm2', 'group_name']);
    // 分页：limit 2 只拿到前两个，游标停在第二个的版本号。
    const page = await getChatDifference(t.db, acc.accountId, chatId, 0, 2);
    expect(page.messages.length + page.events.length).toBe(2);
    expect(page.final).toBe(false);

    // 历史：最新一页带上最后一条消息之后的事件。
    const history = await getHistory(t.db, acc.accountId, chatId, { direction: 'older', limit: 50 });
    expect(history.events.map((e) => e.kind)).toEqual(['member_join', 'group_name']);
    const older = await getHistory(t.db, acc.accountId, chatId, { anchorSeq: 2, direction: 'older', limit: 1 });
    expect(older.messages.map((m) => m.seq)).toEqual([1]);
    expect(older.events).toEqual([]); // 只有 seq 1 这一条且没到开头：事件不在它的时间范围内

    const group = await one<{ name: string }>(t.db, sql`select name from peers where kind = 'group' and peer_id = 910001`);
    expect(group.name).toBe('新群名');
    const proto = chatEventToProto(diff.events[0]!);
    expect(proto).toMatchObject({ kind: 'member_join', actorId: 30003n, targetId: 40004n });
    expect(JSON.parse(proto.dataJson)).toEqual({ via: 'invite' });
  });

  it('merges reactions into messages and pushes typing to online clients only', async () => {
    const { ingest, bus } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 920001, 7, 20002));
    expect(await ingest.applyReaction(acc.qqAccountId, 'group', 920001, 7, { likes: [{ emojiId: '76', count: 1 }], byMe: false, isAdd: true })).toBe(true);
    expect(await ingest.applyReaction(acc.qqAccountId, 'group', 920001, 7, { likes: [{ emojiId: '76', count: 2 }], byMe: true, isAdd: true })).toBe(true);
    expect(await ingest.applyReaction(acc.qqAccountId, 'group', 920001, 99, { likes: [{ emojiId: '1', count: 1 }], byMe: false, isAdd: true })).toBe(false);
    const diff = await getChatDifference(t.db, acc.accountId, chatId, 1);
    expect(diff.messages.at(-1)?.reactions).toEqual([{ emojiId: '76', count: 2, me: true }]);
    expect(messageToProto(diff.messages.at(-1)!).reactions).toEqual([expect.objectContaining({ emojiId: '76', count: 2, me: true })]);

    // "正在输入"：订阅中的客户端收到，不占序号、不写库。
    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 30003, 1, 30003));
    const controller = new AbortController();
    const got: StreamEvent[] = [];
    const stream = (async () => {
      for await (const event of subscribe(t.db, bus, acc.accountId, 1_000_000, controller.signal, { heartbeatMs: 50 })) got.push(event);
    })();
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(await ingest.typing(acc.qqAccountId, 'friend', 30003, 30003, '对方正在输入...')).toBe(true);
    expect(await ingest.typing(acc.qqAccountId, 'friend', 99999, 99999, 'x')).toBe(false); // 不存在的会话
    await new Promise((resolve) => setTimeout(resolve, 100));
    controller.abort();
    await stream;
    const typing = got.filter((e) => e.kind === 'update' && e.update.type === 'typing');
    expect(typing).toHaveLength(1);
  });

  it('reprocesses previously ignored notices from the inbox, resolving short ids to real seqs', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const queueId = `q-${acc.uin}`;
    await t.db.execute(sql`insert into upstream_queues (queue_id, qq_account_id) values (${queueId}, ${acc.qqAccountId})`);
    const r = raw({ chatType: 2, peer: '930001', seq: 555, sender: '20002', elements: [el.text('精华候选')] });
    const message = { ...messageEvent(r), self_id: acc.uin, message_id: 4242 };
    const events = [
      message,
      { post_type: 'notice', notice_type: 'essence', sub_type: 'add', self_id: acc.uin, group_id: 930001, operator_id: 3, sender_id: 20002, message_id: 4242, time: 1_700_000_100 },
      { post_type: 'notice', notice_type: 'notify', sub_type: 'poke', self_id: acc.uin, group_id: 930001, user_id: 20002, target_id: acc.uin, time: 1_700_000_200 },
    ];
    for (const [i, e] of events.entries()) {
      await t.db.execute(
        sql`insert into upstream_events (queue_id, cursor, qq_account_id, kind, payload, state, error, processed_at)
            values (${queueId}, ${i + 1}, ${acc.qqAccountId}, 'x', ${JSON.stringify(e)}::jsonb,
                    ${i === 0 ? 'pending' : 'ignored'}, ${i === 0 ? null : 'not handled yet'}, now())`,
      );
    }
    const inbox = new InboxProcessor(t.db, ingest);
    inbox.poke(acc.qqAccountId);
    await inbox.idle();
    expect(await inbox.reprocess('ignored', acc.qqAccountId)).toBe(2);
    await inbox.idle();
    const states = await rows<{ state: string }>(t.db, sql`select state from upstream_events where queue_id = ${queueId} order by cursor`);
    expect(states.map((s) => s.state)).toEqual(['done', 'done', 'done']);
    const stored = await rows<{ kind: string; ref_seq: number | null }>(
      t.db,
      sql`select e.kind, e.ref_seq from chat_events e join chats c on c.id = e.chat_id where c.qq_account_id = ${acc.qqAccountId} order by e.id`,
    );
    expect(stored).toEqual([
      { kind: 'essence_add', ref_seq: 555 }, // 短 id 4242 → 收件箱里那条消息的真实 seq
      { kind: 'poke', ref_seq: null },
    ]);
    // 再处理一次也不会重复。
    await t.db.execute(sql`update upstream_events set state = 'ignored' where queue_id = ${queueId} and cursor > 1`);
    await inbox.reprocess('ignored', acc.qqAccountId);
    await inbox.idle();
    expect((await rows(t.db, sql`select 1 from chat_events e join chats c on c.id = e.chat_id where c.qq_account_id = ${acc.qqAccountId}`)).length).toBe(2);
  });
});
