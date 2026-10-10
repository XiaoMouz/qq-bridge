// 原件清理：手动清理、按保留策略清理、恢复，以及存储策略接口。
import { randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { Code, createClient, type Interceptor } from '@connectrpc/connect';
import { createConnectTransport } from '@connectrpc/connect-node';
import type { Segment } from '@qqbridge/domain';
import { MediaService as MediaRpc, PolicyScope, Scene } from '@qqbridge/protocol';
import { sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { ApiDeps } from '../src/api/context.ts';
import { buildServer } from '../src/api/server.ts';
import { createDeps } from '../src/app.ts';
import { maybeOne, one } from '../src/db/client.ts';
import { chatStorageRows, recomputeStorage } from '../src/media/accounting.ts';
import { setPolicy } from '../src/media/policies.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { imageMessage } from './helpers/fixtures.ts';

let t: TestDb;
let mediaRoot: string;
let deps: ApiDeps;
let app: FastifyInstance;
let baseUrl: string;
let accountId: number;
let qqAccountId: number;
let token: string;
const DAY = 86_400;
const now = () => Math.floor(Date.now() / 1000);

beforeAll(async () => {
  t = await startTestDb();
  mediaRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-cleanup-'));
  deps = createDeps(t.db, { mediaRoot, mediaUrlSecret: 's'.repeat(40), logLevel: 'silent' });
  app = await buildServer(deps);
  await app.listen({ host: '127.0.0.1', port: 0 });
  baseUrl = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
  accountId = await deps.auth.createAccount('owner', 'password123');
  qqAccountId = await deps.ingest.registerQqAccount(accountId, 10001, 'me');
  token = (await deps.auth.login('owner', 'password123', { name: 'iPhone', platform: 'ios' })).token;
});

afterAll(async () => {
  await app?.close();
  await t?.stop();
  await fs.rm(mediaRoot, { recursive: true, force: true });
});

let seqCounter = 1;

/** 在会话里放一张图（内容 content，time 秒前收到），返回 { chatId, seq, sha256 }。 */
async function image(scene: 'group' | 'friend', peerId: number, content: Buffer, ageSec: number) {
  const seq = seqCounter++;
  const { chatId } = await deps.ingest.ingestMessage(qqAccountId, imageMessage(scene, peerId, seq, 20002, {}, { time: now() - ageSec }));
  const ref = await one<{ id: number }>(t.db, sql`select id from media_refs where chat_id = ${chatId} and message_seq = ${seq}`);
  const blob = await deps.media.storeBlob(Readable.from([content]), { kind: 'image', mime: 'image/png' });
  await deps.ingest.mediaStored(ref.id, blob);
  return { chatId, seq, sha256: blob.sha256 };
}

async function blobState(sha256: string) {
  return (await one<{ state: string }>(t.db, sql`select state from blobs where sha256 = ${sha256}`)).state;
}

async function mediaStateOf(chatId: number, seq: number) {
  const row = await one<{ segments: Segment[] }>(t.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${seq}`);
  return (row.segments[0] as Extract<Segment, { type: 'image' }>).media.state;
}

async function storage(chatId: number) {
  const [row] = await chatStorageRows(t.db, [chatId]);
  return row ?? { chatId, logicalBytes: 0, exclusiveBytes: 0, blobCount: 0 };
}

describe('manual cleanup', () => {
  it('deletes originals nobody else needs, keeps shared ones and thumbnails, and tells the clients', async () => {
    const exclusive = randomBytes(5000);
    const shared = randomBytes(7000);
    const e = await image('group', 610001, exclusive, 10 * DAY);
    const sx = await image('group', 610001, shared, 9 * DAY);
    const sy = await image('friend', 30020, shared, 8 * DAY);
    const thumb = await deps.media.storeBlob(Readable.from([randomBytes(300)]), { kind: 'image', mime: 'image/webp' });
    await t.db.execute(sql`insert into blob_variants (sha256, variant, variant_sha256) values (${e.sha256}, 'thumb', ${thumb.sha256})`);

    const report = await deps.cleaner.execute(accountId, e.chatId, { kinds: ['image'], olderThanDays: 0 });
    expect(report).toEqual({ refCount: 2, blobCount: 2, purgedBlobCount: 1, freedBytes: 5000, keptSharedBlobCount: 1 });
    expect(await blobState(e.sha256)).toBe('purged');
    expect(await blobState(sx.sha256)).toBe('present'); // 另一个会话还需要
    expect(await blobState(thumb.sha256)).toBe('present'); // 缩略图保留
    const signed = deps.signer.sign(e.sha256);
    // 原件不在了：下载接口会去 QQ 重新拿，测试里没有上游，所以是 410（已过期）。
    expect((await fetch(baseUrl + signed.url)).status).toBe(410);
    await expect.poll(() => mediaStateOf(e.chatId, e.seq)).toBe('purged');
    expect(await mediaStateOf(sx.chatId, sx.seq)).toBe('stored');
    expect(await storage(e.chatId)).toMatchObject({ logicalBytes: 7000, exclusiveBytes: 0, blobCount: 1 });

    // 另一个会话也清理之后，共享的内容才删除。
    const second = await deps.cleaner.execute(accountId, sy.chatId, { olderThanDays: 0 });
    expect(second).toMatchObject({ purgedBlobCount: 1, freedBytes: 7000, keptSharedBlobCount: 0 });
    expect(await storage(e.chatId)).toMatchObject({ logicalBytes: 0, blobCount: 0 });
    expect(await storage(sy.chatId)).toMatchObject({ logicalBytes: 0, blobCount: 0 });
    await expect.poll(() => mediaStateOf(sx.chatId, sx.seq)).toBe('purged');
    expect(await recomputeStorage(t.db)).toEqual({ corrected: 0 });

    // 有人又发了这张图：内容重新下载回来，恢复占用与旧消息里的媒体状态。
    const again = await image('friend', 30020, shared, 0);
    expect(again.sha256).toBe(sx.sha256);
    expect(await blobState(sx.sha256)).toBe('present');
    expect(await storage(sy.chatId)).toMatchObject({ logicalBytes: 7000, exclusiveBytes: 0, blobCount: 1 });
    expect(await storage(sx.chatId)).toMatchObject({ logicalBytes: 7000, exclusiveBytes: 0, blobCount: 1 }); // 旧引用也恢复
    await expect.poll(() => mediaStateOf(sy.chatId, sy.seq)).toBe('stored');
    await expect.poll(() => mediaStateOf(sx.chatId, sx.seq)).toBe('stored');
    expect(await recomputeStorage(t.db)).toEqual({ corrected: 0 });
  });
});

describe('retention policies', () => {
  it('purges what every chat lets go of, honours "keep forever", inherits per field, and never touches unsent media', async () => {
    await t.db.execute(sql`delete from storage_policies`);
    const oldP = await image('group', 620001, randomBytes(1000), 60 * DAY);
    const recentP = await image('group', 620001, randomBytes(1000), 1 * DAY);
    const oldQ = await image('group', 620002, randomBytes(1000), 60 * DAY);
    const oldR = await image('group', 620003, randomBytes(1000), 60 * DAY);
    const unsent = await image('group', 620001, randomBytes(1000), 60 * DAY);
    await deps.outbox.enqueue(accountId, null, {
      chatId: oldP.chatId,
      clientRandomId: 777,
      message: { segments: [{ type: 'image', sha256: unsent.sha256 }] },
    });

    await setPolicy(t.db, accountId, { scope: 'global', scene: null, chatId: null, keepOriginalDays: 30, autoFetchMaxBytes: null });
    await setPolicy(t.db, accountId, { scope: 'chat', scene: null, chatId: oldQ.chatId, keepOriginalDays: -1, autoFetchMaxBytes: null });
    // 只调自动下载上限的会话：保留期仍然继承全局的 30 天。
    await setPolicy(t.db, accountId, { scope: 'chat', scene: null, chatId: oldR.chatId, keepOriginalDays: null, autoFetchMaxBytes: 1_000_000 });

    const report = await deps.cleaner.runRetention(now());
    expect(report.purged).toBe(2);
    expect(await blobState(oldP.sha256)).toBe('purged');
    expect(await blobState(oldR.sha256)).toBe('purged');
    expect(await blobState(oldQ.sha256)).toBe('present'); // 永久保留
    expect(await blobState(recentP.sha256)).toBe('present'); // 还没到 30 天
    expect(await blobState(unsent.sha256)).toBe('present'); // 发件箱里还要发
    expect(await recomputeStorage(t.db)).toEqual({ corrected: 0 });

    // 再跑一次：没有新的可清理内容。
    expect((await deps.cleaner.runRetention(now())).purged).toBe(0);
    await t.db.execute(sql`delete from storage_policies`);
  });
});

describe('storage policy API', () => {
  it('sets, lists and deletes policies with per-field inheritance', async () => {
    const auth: Interceptor = (next) => async (req) => {
      req.header.set('authorization', `Bearer ${token}`);
      return next(req);
    };
    const media = createClient(MediaRpc, createConnectTransport({ baseUrl, httpVersion: '1.1', interceptors: [auth] }));
    const chat = await image('group', 630001, randomBytes(100), 0);

    await media.setStoragePolicy({ policy: { scope: PolicyScope.GLOBAL, keepOriginalDays: 90 } });
    await media.setStoragePolicy({ policy: { scope: PolicyScope.SCENE, scene: Scene.GROUP, keepOriginalDays: 0 } });
    await media.setStoragePolicy({
      policy: { scope: PolicyScope.CHAT, chatId: BigInt(chat.chatId), keepOriginalDays: -1, autoFetchMaxBytes: 50_000_000n },
    });
    const listed = (await media.listStoragePolicies({})).policies;
    expect(listed.map((p) => [p.scope, p.scene, p.chatId, p.keepOriginalDays, p.autoFetchMaxBytes])).toEqual([
      [PolicyScope.GLOBAL, Scene.UNSPECIFIED, 0n, 90, undefined],
      [PolicyScope.SCENE, Scene.GROUP, 0n, 0, undefined],
      [PolicyScope.CHAT, Scene.UNSPECIFIED, BigInt(chat.chatId), -1, 50_000_000n],
    ]);

    expect((await media.deleteStoragePolicy({ scope: PolicyScope.CHAT, chatId: BigInt(chat.chatId) })).deleted).toBe(true);
    expect((await media.deleteStoragePolicy({ scope: PolicyScope.CHAT, chatId: BigInt(chat.chatId) })).deleted).toBe(false);
    expect((await media.listStoragePolicies({})).policies).toHaveLength(2);

    await expect(media.setStoragePolicy({ policy: { scope: PolicyScope.SCENE, keepOriginalDays: 1 } })).rejects.toMatchObject({
      code: Code.InvalidArgument,
    });
    await expect(media.setStoragePolicy({ policy: { scope: PolicyScope.GLOBAL, keepOriginalDays: -5 } })).rejects.toMatchObject({
      code: Code.InvalidArgument,
    });
    await expect(media.setStoragePolicy({ policy: { scope: PolicyScope.CHAT, chatId: 999_999n, keepOriginalDays: 1 } })).rejects.toMatchObject({
      code: Code.NotFound,
    });
    await expect(media.executeCleanup({ chatId: 999_999n })).rejects.toMatchObject({ code: Code.NotFound });
    expect(await maybeOne(t.db, sql`select 1 from storage_policies where scope = 'chat'`)).toBeNull();
  });
});
