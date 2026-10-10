// 按需下载：免打扰 / 群助手里的群，图片视频文件不自动下载；显示到时下载、只留缩略图和预览图；看原图时从 QQ 拉。
import fs from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import type { Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { ApiDeps } from '../src/api/context.ts';
import { buildServer } from '../src/api/server.ts';
import { createDeps } from '../src/app.ts';
import { one } from '../src/db/client.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { imageMessage } from './helpers/fixtures.ts';

let t: TestDb;
let mediaRoot: string;
let deps: ApiDeps;
let app: FastifyInstance;
let baseUrl: string;
let accountId: number;
let qqAccountId: number;

beforeAll(async () => {
  t = await startTestDb();
  mediaRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-ondemand-'));
  deps = createDeps(t.db, { mediaRoot, mediaUrlSecret: 's'.repeat(40), logLevel: 'silent' });
  app = await buildServer(deps);
  await app.listen({ host: '127.0.0.1', port: 0 });
  baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
  accountId = await deps.auth.createAccount('owner', 'password123');
  qqAccountId = await deps.ingest.registerQqAccount(accountId, 10001, 'me');
});
afterAll(async () => {
  await app?.close();
  await t?.stop();
  await fs.rm(mediaRoot, { recursive: true, force: true });
});

let seq = 1;
const png = (color: string) => sharp({ create: { width: 640, height: 480, channels: 3, background: color } }).png().toBuffer();

async function chatIdOf(scene: 'group' | 'friend', peerId: number) {
  return (await one<{ id: number }>(t.db, sql`select id from chats where scene = ${scene} and peer_id = ${peerId}`)).id;
}
async function mute(scene: 'group' | 'friend', peerId: number, policy: string) {
  await deps.ingest.ingestMessage(qqAccountId, imageMessage(scene, peerId, seq++, 20002, {}));
  await deps.dialogPrefs.setNotifyPolicy(accountId, await chatIdOf(scene, peerId), policy);
}
async function ref(chatId: number, s: number) {
  return one<{ id: number; fetch_state: string; keep_original: boolean | null }>(
    t.db,
    sql`select id, fetch_state, keep_original from media_refs where chat_id = ${chatId} and message_seq = ${s}`,
  );
}
async function segmentState(chatId: number, s: number) {
  const row = await one<{ segments: Segment[] }>(t.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${s}`);
  return (row.segments[0] as { media: { state: string } }).media.state;
}
/** 模拟下载器：存原件、生成派生版本、标记已存，再走下载后的清理。 */
async function download(refId: number, content: Buffer) {
  const blob = await deps.media.storeBlob(Readable.from([content]), { kind: 'image', mime: 'image/png' });
  const extra = await deps.processor.process(blob.sha256, 'image');
  await deps.ingest.mediaStored(refId, blob, extra);
  await deps.cleaner.purgeIfUnneeded(blob.sha256);
  return blob.sha256;
}
const blobState = async (sha: string) => (await one<{ state: string }>(t.db, sql`select state from blobs where sha256 = ${sha}`)).state;

describe('on-demand media', () => {
  it('does not download images in muted groups until shown, then keeps only thumbnail and preview', async () => {
    await mute('group', 700001, 'muted');
    const chatId = await chatIdOf('group', 700001);
    const s = seq++;
    await deps.ingest.ingestMessage(qqAccountId, imageMessage('group', 700001, s, 20002, {}));
    expect(await ref(chatId, s)).toMatchObject({ fetch_state: 'on_demand', keep_original: false });
    expect(await segmentState(chatId, s)).toBe('on_demand');

    // 客户端显示到：排进下载队列（别的账号要不了）。
    expect(await deps.ingest.requestMedia(accountId + 999, [{ chatId, seq: s, ord: 0 }])).toBe(0);
    expect(await deps.ingest.requestMedia(accountId, [{ chatId, seq: s, ord: 0 }])).toBe(1);
    expect(await ref(chatId, s)).toMatchObject({ fetch_state: 'pending' });
    expect(await segmentState(chatId, s)).toBe('pending');

    const sha = await download((await ref(chatId, s)).id, await png('#336699'));
    expect(await blobState(sha)).toBe('purged');
    const media = ((await one<{ segments: Segment[] }>(t.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${s}`))
      .segments[0] as { media: { state: string; thumbSha256?: string; previewSha256?: string } }).media;
    expect(media.state).toBe('purged');
    expect(media.thumbSha256).toBeTruthy();
    expect(await blobState(media.thumbSha256!)).toBe('present');

    // 看原图：原件不在，服务端去 QQ 拉（测试里没有上游，所以是 410 而不是 404）。
    const { url } = deps.signer.sign(sha);
    expect((await fetch(baseUrl + url)).status).toBe(410);
  });

  it('keeps the original when the same picture also appears in a private chat', async () => {
    await mute('group', 700002, 'archived');
    const groupId = await chatIdOf('group', 700002);
    const content = await png('#996633');
    const s1 = seq++;
    await deps.ingest.ingestMessage(qqAccountId, imageMessage('friend', 800001, s1, 800001, {}));
    const shared = await download((await ref(await chatIdOf('friend', 800001), s1)).id, content);
    const s2 = seq++;
    await deps.ingest.ingestMessage(qqAccountId, imageMessage('group', 700002, s2, 20002, {}));
    await deps.ingest.requestMedia(accountId, [{ chatId: groupId, seq: s2, ord: 0 }]);
    await download((await ref(groupId, s2)).id, content);
    expect(await blobState(shared)).toBe('present');
  });

  it('downloads private chat media right away, and queues on-demand media when a group is unmuted', async () => {
    const s1 = seq++;
    await deps.ingest.ingestMessage(qqAccountId, imageMessage('friend', 800002, s1, 800002, {}));
    expect(await ref(await chatIdOf('friend', 800002), s1)).toMatchObject({ fetch_state: 'pending', keep_original: null });

    await mute('group', 700003, 'muted');
    const chatId = await chatIdOf('group', 700003);
    const s2 = seq++;
    await deps.ingest.ingestMessage(qqAccountId, imageMessage('group', 700003, s2, 20002, {}));
    await deps.dialogPrefs.setNotifyPolicy(accountId, chatId, 'all');
    expect(await ref(chatId, s2)).toMatchObject({ fetch_state: 'pending', keep_original: null });
    expect(await segmentState(chatId, s2)).toBe('pending');
  });
});
