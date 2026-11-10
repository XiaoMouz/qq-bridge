// 只有号码的人：向 QQ 要资料存进 peers、要不到的记下不反复要；群事件入库时带上当时的名字；合并转发补名字和回复摘要。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one, rows } from '../src/db/client.ts';
import { ANONYMOUS_FORWARD_SENDER, PeopleResolver } from '../src/contacts/people.ts';
import { ForwardService } from '../src/messages/forwards.ts';
import { mapRawMessage } from '../src/upstream/napcat/map.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';
import { el, raw } from './helpers/napcat.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

class FakeQq {
  readonly asked: number[] = [];
  strangers = new Map<number, Record<string, unknown>>();
  forward: unknown[] = [];
  isConnected() {
    return true;
  }
  async call<T>(_qq: number, action: string, p: any): Promise<T> {
    if (action === 'x.forward') return { result: 0, messages: this.forward } as T;
    if (action === 'ob11' && p.name === 'get_stranger_info') {
      this.asked.push(Number(p.params.user_id));
      return (this.strangers.get(Number(p.params.user_id)) ?? null) as T;
    }
    throw new Error(`${action} ${p?.name}`);
  }
}

describe('PeopleResolver', () => {
  it('asks QQ only for people without a local name, stores them as peers and remembers misses', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const qq = new FakeQq();
    qq.strangers.set(50001, { user_id: 50001, nickname: '退群的人', uid: 'u_50001' });
    const people = new PeopleResolver(t.db, ingest, () => qq, { minIntervalMs: 0 });
    await ingest.upsertPeer(acc.qqAccountId, { kind: 'user', peerId: 50002, name: '老朋友' });

    await people.ensure(acc.qqAccountId, 920001, [50001, 50002, 50003, undefined, ANONYMOUS_FORWARD_SENDER]);
    expect(qq.asked.sort()).toEqual([50001, 50003]);
    const peer = await one<{ name: string; uid: string; is_friend: boolean }>(
      t.db,
      sql`select name, uid, is_friend from peers where qq_account_id = ${acc.qqAccountId} and kind = 'user' and peer_id = 50001`,
    );
    expect(peer).toEqual({ name: '退群的人', uid: 'u_50001', is_friend: false });
    const misses = await rows<{ user_id: string; found: boolean }>(t.db, sql`select user_id, found from people_lookups order by user_id`);
    expect(misses.map((r) => [Number(r.user_id), r.found])).toEqual([
      [50001, true],
      [50003, false],
    ]);

    // 再来一次：要到的和要不到的都不再问。
    await people.ensure(acc.qqAccountId, 920001, [50001, 50003]);
    expect(qq.asked).toHaveLength(2);
  });

  it('stores the names known at ingest into group events and finds backfill candidates', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const group = 920101;
    await t.db.execute(sql`insert into group_members (qq_account_id, group_id, user_id, nickname, card) values (${acc.qqAccountId}, ${group}, 60001, '昵称', '群名片')`);
    await ingest.upsertPeer(acc.qqAccountId, { kind: 'user', peerId: 60002, name: '好友昵称', remark: '备注' });
    await ingest.addChatEvent(acc.qqAccountId, { scene: 'group', peerId: group, kind: 'poke', time: 1_700_000_000, actorId: 60001, targetId: 60002 });
    await ingest.addChatEvent(acc.qqAccountId, { scene: 'group', peerId: group, kind: 'member_leave', time: 1_700_000_010, targetId: 60003 });
    const events = await rows<{ kind: string; data: Record<string, unknown> }>(
      t.db,
      sql`select e.kind, e.data from chat_events e join chats c on c.id = e.chat_id where c.qq_account_id = ${acc.qqAccountId} order by e.time`,
    );
    expect(events[0]!.data.names).toEqual({ 60001: '群名片', 60002: '备注' });
    expect(events[1]!.data.names).toBeUndefined();

    const people = new PeopleResolver(t.db, ingest, () => null);
    expect(await people.backfillCandidates(acc.qqAccountId)).toEqual([60003]);
  });

  it('fills reply abstracts and numeric sender names in forwards, re-fetching old caches once', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const group = 920201;
    const { chatId } = await ingest.ingestMessage(
      acc.qqAccountId,
      { ...textMessage('group', group, 1, 70009, { extra: [{ type: 'forward', forwardId: 'res1', title: '聊天记录' }] }), qqMsgId: '900' },
    );
    await ingest.upsertPeer(acc.qqAccountId, { kind: 'user', peerId: 70002, name: '被回复的人' });
    await ingest.upsertPeer(acc.qqAccountId, { kind: 'user', peerId: 70003, name: '有名字了' });
    const qq = new FakeQq();
    // 2026-11-10 实测的结构：发送者匿名成「QQ用户」，回复元素里是被回复的真号码和摘要。
    qq.forward = [
      raw({ seq: 10, chatType: 2, peer: String(group), sender: String(ANONYMOUS_FORWARD_SENDER), sendNickName: 'QQ用户', elements: [el.text('[视频]')] }),
      raw({
        seq: 11,
        chatType: 2,
        peer: String(group),
        sender: '70003',
        elements: [
          {
            elementType: 7,
            elementId: '1',
            replyElement: {
              replayMsgSeq: '10',
              senderUid: '70002',
              sourceMsgTextElems: [
                { replyAbsElemType: 1, textElemContent: '看这个', picElem: null },
                { replyAbsElemType: 2, faceElem: { faceText: null } },
                { replyAbsElemType: 3, picElem: { picText: '[动画表情]' } },
              ],
            },
          },
          el.text('这是啥'),
        ] as any,
      }),
    ];
    const forwards = new ForwardService(t.db, ingest, () => qq);
    const first = await forwards.get(acc.accountId, chatId, 1, []);
    expect(first.nodes.map((n) => n.senderName)).toEqual(['QQ用户', '有名字了']);
    expect(first.nodes[1]!.segments[0]).toEqual({ type: 'reply', seq: 10, senderId: 70002, text: '看这个[表情][动画表情]', name: '被回复的人' });

    // 以前存的缓存：回复段没有 text。打开时向 QQ 重拉一次补上。
    const old = first.nodes.map((n) => ({ ...n, segments: n.segments.map((s) => (s.type === 'reply' ? { type: 'reply', seq: s.seq, senderId: s.senderId } : s)) }));
    await t.db.execute(sql`update forward_bundles set nodes = ${JSON.stringify(old)}::jsonb, fetched_at = now() - interval '2 days' where chat_id = ${chatId}`);
    const again = await forwards.get(acc.accountId, chatId, 1, []);
    expect((again.nodes[1]!.segments[0] as any).text).toBe('看这个[表情][动画表情]');
  });

  it('maps the reply abstract of live messages', () => {
    const action = mapRawMessage(
      raw({
        seq: 5,
        chatType: 2,
        peer: '920301',
        sender: '10001',
        elements: [{ elementType: 7, elementId: '1', replyElement: { replayMsgSeq: '4', senderUid: '20002', sourceMsgTextElems: [{ replyAbsElemType: 9 }] } }, el.text('x')],
      }),
      { selfUin: 99, source: 'realtime' },
    );
    if (action.type !== 'message') throw new Error(action.type);
    // 没见过的摘要类型不拼，也不写空的 text。
    expect(action.message.segments[0]).toEqual({ type: 'reply', seq: 4, senderId: 20002 });
  });
});
