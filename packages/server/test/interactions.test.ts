// 表情回应、"正在输入"、共享媒体、合并转发展开。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one, rows } from '../src/db/client.ts';
import { ForwardService } from '../src/messages/forwards.ts';
import { InteractionError, MessageInteractions } from '../src/messages/interactions.ts';
import type { NtRawMessage } from '../src/upstream/napcat/types.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, imageMessage, services, textMessage, type TestAccount } from './helpers/fixtures.ts';
import { el, raw } from './helpers/napcat.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

class FakeHub {
  online = true;
  readonly calls: { action: string; params: any }[] = [];
  forwards = new Map<string, NtRawMessage[]>();
  isConnected() {
    return this.online;
  }
  async call<T>(_qq: number, action: string, params: any): Promise<T> {
    this.calls.push({ action, params });
    if (action === 'x.forward') return { result: 0, messages: this.forwards.get(params.parentMsgId) ?? [] } as T;
    return { ok: true } as T;
  }
}

async function chatIdOf(acc: TestAccount, peerId: number): Promise<number> {
  return (await one<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId} and peer_id = ${peerId}`)).id;
}

describe('MessageInteractions', () => {
  it('reacts in groups, writes the new count right away and refuses where QQ cannot', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const hub = new FakeHub();
    const it_ = new MessageInteractions(t.db, ingest, () => hub);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 940001, 5, 20002));
    await ingest.applyReaction(acc.qqAccountId, 'group', 940001, 5, { likes: [{ emojiId: '76', count: 2 }], byMe: false, isAdd: true });
    const group = await chatIdOf(acc, 940001);

    const added = await it_.react(acc.accountId, group, 5, '76', true);
    expect(added.reactions).toEqual([{ emojiId: '76', count: 3, me: true }]);
    expect(hub.calls.at(-1)).toMatchObject({ action: 'x.react', params: { chatType: 2, peerUin: '940001', seq: '5', emojiId: '76', add: true } });
    expect((await it_.react(acc.accountId, group, 5, '76', true)).reactions).toEqual([{ emojiId: '76', count: 3, me: true }]); // 重复点不会多算
    expect((await it_.react(acc.accountId, group, 5, '76', false)).reactions).toEqual([{ emojiId: '76', count: 2 }]);

    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 30030, 1, 30030));
    await expect(it_.react(acc.accountId, await chatIdOf(acc, 30030), 1, '76', true)).rejects.toMatchObject({ code: 'unsupported' });
    hub.online = false;
    await expect(it_.react(acc.accountId, group, 5, '76', true)).rejects.toMatchObject({ code: 'offline' });
    await expect(it_.react(acc.accountId, group, 5, '../x', true)).rejects.toBeInstanceOf(InteractionError);
  });

  it('sends typing to friends at most every few seconds', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const hub = new FakeHub();
    const it_ = new MessageInteractions(t.db, ingest, () => hub);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('friend', 30031, 1, 30031));
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 940002, 1, 20002));
    const friend = await chatIdOf(acc, 30031);
    expect(await it_.typing(acc.accountId, friend)).toBe(true);
    expect(await it_.typing(acc.accountId, friend)).toBe(false);
    expect(await it_.typing(acc.accountId, await chatIdOf(acc, 940002))).toBe(false);
    expect(hub.calls).toEqual([{ action: 'ob11', params: { name: 'set_input_status', params: { user_id: '30031', event_type: 1 } } }]);
  });

  it('lists shared media newest first without stickers, page by page', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const it_ = new MessageInteractions(t.db, ingest, () => null);
    for (let seq = 1; seq <= 5; seq++) await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 940003, seq, 20002, { qqMd5: `${seq}`.repeat(32) }));
    const sticker = imageMessage('group', 940003, 6, 20002, { qqMd5: 'f'.repeat(32) });
    sticker.media[0]!.role = 'sticker';
    await ingest.ingestMessage(acc.qqAccountId, sticker);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 940003, 7, 20002));
    const chat = await chatIdOf(acc, 940003);

    const first = await it_.sharedMedia(acc.accountId, chat, { kinds: [], limit: 3 });
    expect(first.items.map((i) => i.seq)).toEqual([5, 4, 3]);
    expect(first.items[0]).toMatchObject({ kind: 'image', senderId: 20002, segment: { type: 'image' } });
    const second = await it_.sharedMedia(acc.accountId, chat, { kinds: [], beforeSeq: first.nextBeforeSeq, limit: 3 });
    expect(second.items.map((i) => i.seq)).toEqual([2, 1]);
    expect(second.nextBeforeSeq).toBe(0);
    expect((await it_.sharedMedia(acc.accountId, chat, { kinds: ['sticker', 'image'], limit: 10 })).items.map((i) => i.seq)).toEqual([6, 5, 4, 3, 2, 1]);
  });
});

describe('ForwardService', () => {
  it('fetches a forward once, caches it, registers its media and expands nested forwards', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const hub = new FakeHub();
    const forwards = new ForwardService(t.db, ingest, () => hub);
    const outer = { ...textMessage('group', 940004, 9, 20002, { extra: [{ type: 'forward', forwardId: 'res-1' }] }), qqMsgId: '7300000000000000009' };
    await ingest.ingestMessage(acc.qqAccountId, outer);
    const chat = await chatIdOf(acc, 940004);

    const nested = raw({ chatType: 2, peer: '940004', seq: 2, sender: '30041', sendNickName: '乙', elements: [el.forward('res-2', '<msg/>')] });
    hub.forwards.set('7300000000000000009', [
      raw({ chatType: 2, peer: '940004', seq: 1, sender: '30040', sendNickName: '甲', elements: [el.text('第一条'), el.pic({ md5: 'a'.repeat(32), size: 10, w: 1, h: 1 })] }),
      nested,
    ]);
    hub.forwards.set(String(nested.msgId), [raw({ chatType: 2, peer: '940004', seq: 1, sender: '30042', elements: [el.text('里层')] })]);

    const top = await forwards.get(acc.accountId, chat, 9, []);
    expect(top.state).toBe('ready');
    expect(top.nodes.map((n) => [n.senderId, n.senderName])).toEqual([
      [30040, '甲'],
      [30041, '乙'],
    ]);
    expect(top.nodes[0]!.segments.map((s) => s.type)).toEqual(['text', 'image']);
    const refs = await rows<{ forward_bundle_id: string; node_path: number[]; kind: string }>(
      t.db,
      sql`select forward_bundle_id, node_path, kind from media_refs where chat_id = ${chat}`,
    );
    expect(refs).toEqual([{ forward_bundle_id: String(top.id), node_path: [0], kind: 'image' }]);

    await forwards.get(acc.accountId, chat, 9, []);
    expect(hub.calls.filter((c) => c.action === 'x.forward')).toHaveLength(1); // 第二次读缓存

    const inner = await forwards.get(acc.accountId, chat, 9, [1]);
    expect(inner.nodes.map((n) => n.segments)).toEqual([[{ type: 'text', text: '里层' }]]);
    expect(hub.calls.at(-1)?.params).toMatchObject({ rootMsgId: '7300000000000000009', parentMsgId: String(nested.msgId) });
    await expect(forwards.get(acc.accountId, chat, 9, [0])).rejects.toMatchObject({ code: 'not_found' }); // 第 0 个节点不是合并转发

    // 下载完成后，缓存里的媒体信息跟着更新。
    const ref = await one<{ id: number }>(t.db, sql`select id from media_refs where chat_id = ${chat}`);
    await t.db.execute(
      sql`insert into blobs (sha256, md5, md5_head, size, storage_key) values (${'b'.repeat(64)}, ${'a'.repeat(32)}, ${'a'.repeat(32)}, 10, 'k')`,
    );
    await ingest.mediaStored(ref.id, { sha256: 'b'.repeat(64), size: 10, mime: 'image/png' });
    const again = await forwards.get(acc.accountId, chat, 9, []);
    expect(again.nodes[0]!.segments[1]).toMatchObject({ type: 'image', media: { state: 'stored', sha256: 'b'.repeat(64) } });
  });

  it('remembers forwards QQ no longer has', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const hub = new FakeHub();
    const forwards = new ForwardService(t.db, ingest, () => hub);
    await ingest.ingestMessage(acc.qqAccountId, { ...textMessage('group', 940005, 1, 20002, { extra: [{ type: 'forward', forwardId: 'gone' }] }), qqMsgId: '1' });
    const chat = await chatIdOf(acc, 940005);
    expect((await forwards.get(acc.accountId, chat, 1, [])).state).toBe('unavailable');
    await forwards.get(acc.accountId, chat, 1, []);
    expect(hub.calls).toHaveLength(1);
  });
});
