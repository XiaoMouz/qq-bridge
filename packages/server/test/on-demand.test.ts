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
import { one, rows } from '../src/db/client.ts';
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
const LOCATOR = { elementType: 2, msgId: '1', elementId: '1', peerUid: 'g', chatType: 2 };
const photo = (scene: 'group' | 'friend', peerId: number, s: number) =>
  imageMessage(scene, peerId, s, 20002, { url: 'https://multimedia.nt.qq.com.cn/download?appid=1407&fileid=abc&rkey=k&spec=0', locator: LOCATOR });
const png = (color: string) => sharp({ create: { width: 640, height: 480, channels: 3, background: color } }).png().toBuffer();

async function chatIdOf(scene: 'group' | 'friend', peerId: number) {
  return (await one<{ id: number }>(t.db, sql`select id from chats where scene = ${scene} and peer_id = ${peerId}`)).id;
}
async function setPolicy(scene: 'group' | 'friend', peerId: number, policy: string) {
  await deps.ingest.ingestMessage(qqAccountId, imageMessage(scene, peerId, seq++, 20002, {}));
  await deps.dialogPrefs.setNotifyPolicy(accountId, await chatIdOf(scene, peerId), policy);
}
async function refs(chatId: number, s: number) {
  const list = await rows<{ id: number; role: string; fetch_state: string; keep_original: boolean | null }>(
    t.db,
    sql`select id, role, fetch_state, keep_original from media_refs where chat_id = ${chatId} and message_seq = ${s} order by id`,
  );
  return { original: list.find((r) => r.role !== 'qq_thumb')!, thumb: list.find((r) => r.role === 'qq_thumb') };
}
async function mediaOf(chatId: number, s: number) {
  const row = await one<{ segments: Segment[] }>(t.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${s}`);
  return (row.segments[0] as { media: { state: string; sha256?: string; thumbSha256?: string; previewSha256?: string } }).media;
}
const blobState = async (sha: string) => (await one<{ state: string }>(t.db, sql`select state from blobs where sha256 = ${sha}`)).state;
async function store(content: Buffer) {
  return deps.media.storeBlob(Readable.from([content]), { kind: 'image', mime: 'image/png' });
}

describe('image downloads', () => {
  it('in private chats: fetches only the QQ thumbnail right away; the original waits until it is opened', async () => {
    const s = seq++;
    await deps.ingest.ingestMessage(qqAccountId, photo('friend', 810001, s));
    const chatId = await chatIdOf('friend', 810001);
    const { original, thumb } = await refs(chatId, s);
    expect(original).toMatchObject({ fetch_state: 'on_demand', keep_original: null });
    expect(thumb).toMatchObject({ fetch_state: 'pending' });
    expect((await mediaOf(chatId, s)).state).toBe('on_demand');

    // QQ 缩略图下好：记进消息的缩略图，原图仍是按需，不生成自己的缩略图 / 预览图。
    const t1 = await store(await png('#224466'));
    await deps.ingest.thumbStored(thumb!.id, t1);
    expect(await mediaOf(chatId, s)).toMatchObject({ state: 'on_demand', thumbSha256: t1.sha256 });

    // 看大图：要原图。
    expect(await deps.ingest.requestMedia(accountId, [{ chatId, seq: s, ord: 0 }], 'original')).toEqual([original.id]);
    expect((await mediaOf(chatId, s)).state).toBe('pending');
    const orig = await store(await png('#446688'));
    await deps.ingest.mediaStored(original.id, orig, await deps.processor.process(orig.sha256, 'image'));
    const after = await mediaOf(chatId, s);
    expect(after).toMatchObject({ state: 'stored', sha256: orig.sha256, thumbSha256: t1.sha256 });
    expect(after.previewSha256).toBeUndefined();
    expect(await blobState(orig.sha256)).toBe('present'); // 常用会话：看过的原图留着
  });

  it('in groups (muted or not): nothing is fetched until the image is shown', async () => {
    await setPolicy('group', 710001, 'muted');
    const chatId = await chatIdOf('group', 710001);
    const s = seq++;
    await deps.ingest.ingestMessage(qqAccountId, photo('group', 710001, s));
    const { original, thumb } = await refs(chatId, s);
    expect(original).toMatchObject({ fetch_state: 'on_demand', keep_original: false });
    expect(thumb).toMatchObject({ fetch_state: 'on_demand' });

    // 显示到：要 QQ 缩略图（别的账号要不了）。
    expect(await deps.ingest.requestMedia(accountId + 999, [{ chatId, seq: s, ord: 0 }])).toEqual([]);
    expect(await deps.ingest.requestMedia(accountId, [{ chatId, seq: s, ord: 0 }])).toEqual([thumb!.id]);
    expect((await refs(chatId, s)).thumb).toMatchObject({ fetch_state: 'pending' });
    expect((await mediaOf(chatId, s)).state).toBe('on_demand');
  });

  it('adds a thumbnail reference for images archived before thumbnails existed', async () => {
    const s = seq++;
    const msg = photo('group', 710002, s);
    await deps.ingest.ingestMessage(qqAccountId, msg);
    const chatId = await chatIdOf('group', 710002);
    await t.db.execute(sql`delete from media_refs where chat_id = ${chatId} and message_seq = ${s} and role = 'qq_thumb'`);
    const queued = await deps.ingest.requestMedia(accountId, [{ chatId, seq: s, ord: 0 }]);
    expect(queued).toHaveLength(1);
    expect((await refs(chatId, s)).thumb).toMatchObject({ id: queued[0], fetch_state: 'pending' });
  });

  it('normal (not muted) groups do not download on their own either', async () => {
    await setPolicy('group', 710005, 'all');
    const chatId = await chatIdOf('group', 710005);
    const s = seq++;
    await deps.ingest.ingestMessage(qqAccountId, photo('group', 710005, s));
    expect(await refs(chatId, s)).toMatchObject({
      original: { fetch_state: 'on_demand', keep_original: null },
      thumb: { fetch_state: 'on_demand' },
    });
  });

  it('unmuting a group only changes whether originals are kept: groups never download on their own', async () => {
    await setPolicy('group', 710003, 'archived');
    const chatId = await chatIdOf('group', 710003);
    const s = seq++;
    await deps.ingest.ingestMessage(qqAccountId, photo('group', 710003, s));
    await deps.dialogPrefs.setNotifyPolicy(accountId, chatId, 'all');
    expect(await refs(chatId, s)).toMatchObject({
      original: { fetch_state: 'on_demand', keep_original: null },
      thumb: { fetch_state: 'on_demand' },
    });
  });

  it('animated stickers need the original: fetched right away in normal chats, when shown in muted groups', async () => {
    const sticker = (scene: 'group' | 'friend', peerId: number, s: number) => {
      const m = photo(scene, peerId, s);
      return { ...m, media: m.media.map((x) => ({ ...x, role: 'sticker' as const })) };
    };
    const s1 = seq++;
    await deps.ingest.ingestMessage(qqAccountId, sticker('friend', 810002, s1));
    const friendChat = await chatIdOf('friend', 810002);
    expect(await refs(friendChat, s1)).toMatchObject({ original: { fetch_state: 'pending' }, thumb: undefined });

    await setPolicy('group', 710004, 'muted');
    const groupChat = await chatIdOf('group', 710004);
    const s2 = seq++;
    await deps.ingest.ingestMessage(qqAccountId, sticker('group', 710004, s2));
    const { original, thumb } = await refs(groupChat, s2);
    expect(original).toMatchObject({ fetch_state: 'on_demand' });
    expect(thumb).toBeUndefined();
    // 显示到：要的是原图（不是 QQ 缩略图）。
    expect(await deps.ingest.requestMedia(accountId, [{ chatId: groupChat, seq: s2, ord: 0 }])).toEqual([original.id]);
  });

  it('serving a purged original goes back to QQ instead of a plain 404', async () => {
    const blob = await store(await png('#887766'));
    await deps.media.purgeOriginal(blob.sha256);
    const { url } = deps.signer.sign(blob.sha256);
    expect((await fetch(baseUrl + url)).status).toBe(410); // 测试里没有上游：拿不到 = 已过期
  });
});
