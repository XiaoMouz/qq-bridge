// 转发：逐条 / 打包（合并转发，保留发送者），媒体按 sha256 引用；以及打包后的 OneBot node 段。
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { validateOutgoing, type OutgoingSegment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { ApiDeps } from '../src/api/context.ts';
import { createDeps } from '../src/app.ts';
import { one, rows } from '../src/db/client.ts';
import { toOb11 } from '../src/outbox/ob11.ts';
import { sqlList } from '../src/sync/rows.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { imageMessage, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
let mediaRoot: string;
let deps: ApiDeps;
let accountId: number;
let qqAccountId: number;

beforeAll(async () => {
  t = await startTestDb();
  mediaRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-fwd-'));
  deps = createDeps(t.db, { mediaRoot, mediaUrlSecret: 's'.repeat(40), logLevel: 'silent' });
  accountId = await deps.auth.createAccount('owner', 'password123');
  qqAccountId = await deps.ingest.registerQqAccount(accountId, 10001, '我自己');
});
afterAll(async () => {
  await t?.stop();
  await fs.rm(mediaRoot, { recursive: true, force: true });
});

const chatIdOf = async (scene: string, peer: number) =>
  (await one<{ id: number }>(t.db, sql`select id from chats where scene = ${scene} and peer_id = ${peer}`)).id;

async function setup() {
  // 来源群：两条文字（一条带 @）和一张已下好的图；目标：一个私聊。
  await deps.ingest.ingestMessage(qqAccountId, textMessage('group', 900001, 1, 20002, { text: '第一条', extra: [{ type: 'mention', userId: 30003, name: '小明' }] }));
  await deps.ingest.ingestMessage(qqAccountId, imageMessage('group', 900001, 2, 30003, {}));
  const from = await chatIdOf('group', 900001);
  const ref = await one<{ id: number }>(t.db, sql`select id from media_refs where chat_id = ${from} and message_seq = 2`);
  const blob = await deps.media.storeBlob(Readable.from([Buffer.from('a picture')]), { kind: 'image', mime: 'image/png' });
  await deps.ingest.mediaStored(ref.id, blob);
  await deps.ingest.ingestMessage(qqAccountId, textMessage('group', 900001, 3, 10001, { text: '我说的', self: true }));
  await t.db.execute(sql`insert into group_members (qq_account_id, group_id, user_id, nickname, card) values
    (${qqAccountId}, 900001, 20002, '张三昵称', '张三'), (${qqAccountId}, 900001, 30003, '李四', null) on conflict do nothing`);
  await deps.ingest.ingestMessage(qqAccountId, textMessage('friend', 800001, 1, 800001, { text: 'hi' }));
  return { from, to: await chatIdOf('friend', 800001), sha: blob.sha256 };
}

const contents = async (ids: number[]) =>
  (await rows<{ content: { segments: OutgoingSegment[] } }>(t.db, sql`select content from outbox where id in ${sqlList(ids)} order by id`)).map((r) => r.content.segments);

describe('forwarding', () => {
  it('forwards one by one, in order, mentions as plain text and media by sha256', async () => {
    const { from, to, sha } = await setup();
    const entries = await deps.forwarder.forward(accountId, null, { fromChatId: from, seqs: [3, 1, 2], toChatIds: [to], bundle: false });
    expect(entries.map((e) => e.chatId)).toEqual([to, to, to]);
    expect(await contents(entries.map((e) => e.id))).toEqual([
      [{ type: 'text', text: '@小明 第一条' }],
      [{ type: 'image', sha256: sha }],
      [{ type: 'text', text: '我说的' }],
    ]);
  });

  it('bundles into one merged forward that keeps each sender and name', async () => {
    const { from, to, sha } = await setup();
    const [entry, ...rest] = await deps.forwarder.forward(accountId, null, { fromChatId: from, seqs: [1, 2, 3], toChatIds: [to], bundle: true });
    expect(rest).toEqual([]);
    const [segments] = await contents([entry!.id]);
    expect(segments).toEqual([
      {
        type: 'forward',
        nodes: [
          { userId: 20002, nickname: '张三', segments: [{ type: 'text', text: '@小明 第一条' }] },
          { userId: 30003, nickname: '李四', segments: [{ type: 'image', sha256: sha }] },
          { userId: 10001, nickname: '我自己', segments: [{ type: 'text', text: '我说的' }] },
        ],
      },
    ]);
    const ob11 = toOb11({ segments: segments! }, (s, n) => `http://m/${s}/${n}`, new Map([[sha, 'image/png']]));
    expect(ob11.map((s) => s.type)).toEqual(['node', 'node', 'node']);
    expect(ob11[1]).toMatchObject({ data: { user_id: '30003', nickname: '李四', content: [{ type: 'image', data: { file: expect.stringContaining(sha) } }] } });
  });

  it('rejects forwards from chats of other accounts and validates nodes', async () => {
    const { from, to } = await setup();
    await expect(deps.forwarder.forward(accountId + 99, null, { fromChatId: from, seqs: [1], toChatIds: [to], bundle: true })).rejects.toThrow(/not found/);
    expect(validateOutgoing({ segments: [{ type: 'forward', nodes: [] }] })).toMatch(/nodes/);
    expect(validateOutgoing({ segments: [{ type: 'text', text: 'x' }, { type: 'forward', nodes: [{ userId: 1, nickname: 'a', segments: [{ type: 'text', text: 'y' }] }] }] })).toMatch(/own/);
  });
});
