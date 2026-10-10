import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import type { MediaInfo, Segment } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { maybeOne, one, rows, toDate } from '../src/db/client.ts';
import type { IngestService } from '../src/ingest/service.ts';
import { MediaFetcher, type FetcherOptions } from '../src/media/fetcher.ts';
import { MediaProcessor } from '../src/media/processing.ts';
import { MediaService } from '../src/media/service.ts';
import { StoredUrlSource, type MediaSource, type PendingRef } from '../src/media/source.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { NapcatMediaSource } from '../src/upstream/napcat/media-source.ts';
import { getChatDifference } from '../src/sync/difference.ts';
import { THUMB_PX } from '../src/media/variants.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, imageMessage, services, type TestAccount } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
let media: MediaService;
let ingest: IngestService;
let acc: TestAccount;
let server: http.Server;
let base: string;

/** 测试用的"QQ 媒体服务器"：按路径返回内容、错误码、限流失败等。 */
const files = new Map<string, { body: Buffer; type: string }>();
const hits = new Map<string, number>();
const failuresLeft = new Map<string, number>();

function hit(key: string): number {
  const n = (hits.get(key) ?? 0) + 1;
  hits.set(key, n);
  return n;
}

beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-fetch-'));
  media = new MediaService(t.db, new LocalFsBackend(root));
  ingest = services(t.db).ingest;
  acc = await createTestAccount(t.db, ingest);

  server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://x');
    const [, route, name = '', arg] = url.pathname.split('/');
    hit(url.pathname);
    const file = files.get(name);
    switch (route) {
      case 'file':
        if (!file) return void res.writeHead(404).end();
        res.writeHead(200, { 'content-type': file.type, 'content-length': file.body.length });
        return void res.end(file.body);
      case 'chunked': // 不带 Content-Length，只能边下载边数
        if (!file) return void res.writeHead(404).end();
        res.writeHead(200, { 'content-type': file.type });
        for (let i = 0; i < file.body.length; i += 1024) res.write(file.body.subarray(i, i + 1024));
        return void res.end();
      case 'status':
        return void res.writeHead(Number(name)).end();
      case 'flaky': {
        const left = failuresLeft.get(url.pathname) ?? Number(arg ?? 0);
        if (left > 0) {
          failuresLeft.set(url.pathname, left - 1);
          return void res.writeHead(500).end();
        }
        if (!file) return void res.writeHead(404).end();
        res.writeHead(200, { 'content-type': file.type });
        return void res.end(file.body);
      }
      case 'slow':
        setTimeout(() => {
          if (!file) return void res.writeHead(404).end();
          res.writeHead(200, { 'content-type': file.type });
          res.end(file.body);
        }, 50);
        return;
      default:
        res.writeHead(404).end();
    }
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterAll(async () => {
  await new Promise((resolve) => server?.close(resolve));
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

const sha256 = (b: Buffer) => createHash('sha256').update(b).digest('hex');
const md5 = (b: Buffer) => createHash('md5').update(b).digest('hex');

async function png(width: number, height: number, color: { r: number; g: number; b: number }): Promise<Buffer> {
  return sharp({ create: { width, height, channels: 3, background: color } }).png().toBuffer();
}

let peerCounter = 50_000;
function nextPeer() {
  return peerCounter++;
}

function fetcher(source: MediaSource = new StoredUrlSource(), opts: FetcherOptions = {}) {
  return new MediaFetcher(t.db, media, ingest, source, { backoffBaseMs: 60_000, pollMs: 20, ...opts }, new MediaProcessor(t.db, media));
}

// 私聊：媒体自动下载（群聊从不自动下载，见 on-demand.test.ts）。

async function ingestImage(peerId: number, seq: number, media: Parameters<typeof imageMessage>[4]) {
  return ingest.ingestMessage(acc.qqAccountId, imageMessage('friend', peerId, seq, peerId, media));
}

async function refOf(chatId: number, seq = 1) {
  return one<{ id: number; fetch_state: string; sha256: string | null; attempts: number; last_error: string | null; next_attempt_at: string | Date | null; thumbhash: string | null }>(
    t.db,
    sql`select id, fetch_state, sha256, attempts, last_error, next_attempt_at, thumbhash from media_refs where chat_id = ${chatId} and message_seq = ${seq} and role <> 'qq_thumb'`,
  );
}

async function mediaOf(chatId: number, seq = 1): Promise<MediaInfo> {
  const row = await one<{ segments: Segment[] }>(t.db, sql`select segments from messages where chat_id = ${chatId} and seq = ${seq}`);
  const seg = row.segments[0] as Extract<Segment, { type: 'image' }>;
  return seg.media;
}

async function readBlob(sha: string): Promise<Buffer> {
  const blob = await media.getBlob(sha);
  const chunks: Buffer[] = [];
  for await (const chunk of await media.openBlob(blob!)) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}

/** 让失败后等待重试的引用立即到期。 */
async function makeDue(refId: number) {
  await t.db.execute(sql`update media_refs set next_attempt_at = now() - interval '1 second' where id = ${refId}`);
}

describe('MediaFetcher', () => {
  it('downloads an image as is (no re-encoded thumbnails), and pushes the update to the chat', async () => {
    const body = await png(2000, 1000, { r: 200, g: 120, b: 40 });
    files.set('a.png', { body, type: 'image/png' });
    const { chatId } = await ingestImage(nextPeer(), 1, { url: `${base}/file/a.png`, size: body.length });
    const before = await one<{ chat_pts: number }>(t.db, sql`select chat_pts from chats where id = ${chatId}`);

    expect(await fetcher().runOnce()).toBe(1);

    const ref = await refOf(chatId);
    expect(ref).toMatchObject({ fetch_state: 'stored', sha256: sha256(body), last_error: null, next_attempt_at: null });

    // 只读宽高，不自己生成缩略图 / 预览图（缩略图用 QQ 给的，客户端有原图时直接显示原图）。
    const info = await mediaOf(chatId);
    expect(info).toMatchObject({ state: 'stored', sha256: sha256(body), size: body.length, mime: 'image/png', width: 2000, height: 1000 });
    expect(info.thumbSha256).toBeUndefined();
    expect(info.previewSha256).toBeUndefined();
    expect(await readBlob(info.sha256!)).toEqual(body);

    // 原件计入会话占用；客户端经 chat_pts 收到"媒体已就绪"。
    const usage = await rows(t.db, sql`select sha256 from chat_blob_usage where chat_id = ${chatId}`);
    expect(usage).toEqual([{ sha256: sha256(body) }]);
    const diff = await getChatDifference(t.db, acc.accountId, chatId, before.chat_pts);
    expect(diff.messages).toHaveLength(1);
    expect(diff.messages[0]!.segments[0]).toMatchObject({ media: { state: 'stored', sha256: sha256(body) } });
  });

  it('stores the same content once and reuses its variants; a known QQ md5 skips the download entirely', async () => {
    const body = await png(800, 600, { r: 10, g: 200, b: 90 });
    files.set('b.png', { body, type: 'image/png' });
    const first = await ingestImage(nextPeer(), 1, { url: `${base}/file/b.png`, size: body.length });
    await fetcher().runOnce();
    const firstInfo = await mediaOf(first.chatId);
    const blobsBefore = await one<{ n: number }>(t.db, sql`select count(*)::int as n from blobs`);

    // 另一个会话，没有 md5：照常下载，但内容按 sha256 去重，派生版本直接复用。
    const second = await ingestImage(nextPeer(), 1, { url: `${base}/file/b.png?copy`, size: body.length });
    await fetcher().runOnce();
    const secondInfo = await mediaOf(second.chatId);
    expect(secondInfo).toMatchObject({ state: 'stored', sha256: firstInfo.sha256, width: 800, height: 600 });
    expect(await one<{ n: number }>(t.db, sql`select count(*)::int as n from blobs`)).toEqual(blobsBefore);

    // 第三个会话带着 QQ md5：入库时就命中，不进下载队列，也带上了缩略图信息。
    const requests = hits.get('/file/b.png') ?? 0;
    const third = await ingestImage(nextPeer(), 1, { url: `${base}/file/b.png`, size: body.length, qqMd5: md5(body) });
    expect(await refOf(third.chatId)).toMatchObject({ fetch_state: 'stored', sha256: firstInfo.sha256 });
    expect(await mediaOf(third.chatId)).toMatchObject({ state: 'stored', sha256: firstInfo.sha256, width: 800, height: 600 });
    expect(await fetcher().runOnce()).toBe(0);
    expect(hits.get('/file/b.png') ?? 0).toBe(requests);
  });

  it('asks the source for a fresh link once when the stored one is gone, and marks it expired otherwise', async () => {
    const body = await png(100, 100, { r: 1, g: 2, b: 3 });
    files.set('c.png', { body, type: 'image/png' });
    const refreshed: PendingRef[] = [];
    const source = new StoredUrlSource(async (ref) => {
      refreshed.push(ref);
      return `${base}/file/c.png`;
    });
    const ok = await ingestImage(nextPeer(), 1, { url: `${base}/status/403`, size: body.length });
    await fetcher(source).runOnce();
    expect(refreshed.map((r) => r.id)).toEqual([(await refOf(ok.chatId)).id]);
    expect(await refOf(ok.chatId)).toMatchObject({ fetch_state: 'stored', sha256: sha256(body) });
    // 小图（不大于缩略图尺寸）没有单独的预览图。
    expect(await mediaOf(ok.chatId)).toMatchObject({ state: 'stored', width: 100, height: 100 });
    expect((await mediaOf(ok.chatId)).previewSha256).toBeUndefined();

    // 没有 refresher（上游未接入）：链接失效就记为 expired，不再重试。
    const gone = await ingestImage(nextPeer(), 1, { url: `${base}/status/410` });
    await fetcher().runOnce();
    expect(await refOf(gone.chatId)).toMatchObject({ fetch_state: 'expired', sha256: null, last_error: 'HTTP 410', next_attempt_at: null });
    expect(await mediaOf(gone.chatId)).toMatchObject({ state: 'expired' });

    // 入库时就没有可用链接（例如已过期）也一样。
    const stale = await ingestImage(nextPeer(), 1, { url: `${base}/file/c.png`, urlExpiresAt: 1_000 });
    await fetcher().runOnce();
    expect(await refOf(stale.chatId)).toMatchObject({ fetch_state: 'expired', last_error: 'no download url' });
  });

  it('skips media over the auto-fetch limit: by declared size, by Content-Length, or while streaming', async () => {
    const body = await png(600, 600, { r: 255, g: 0, b: 0 });
    files.set('d.png', { body, type: 'image/png' });
    const limit = body.length - 1;
    const peers = [nextPeer(), nextPeer(), nextPeer()];
    await t.db.execute(sql`insert into storage_policies (account_id, scope, auto_fetch_max_bytes) values (${acc.accountId}, 'global', ${limit})`);
    try {
      const declared = await ingestImage(peers[0]!, 1, { url: `${base}/file/d.png?declared`, size: body.length });
      const header = await ingestImage(peers[1]!, 1, { url: `${base}/file/d.png?header` });
      const streamed = await ingestImage(peers[2]!, 1, { url: `${base}/chunked/d.png` });
      await fetcher().runOnce(10);

      expect(hits.get('/file/d.png') ?? 0).toBe(1); // 声明了大小的那条根本没发请求
      for (const { chatId } of [declared, header, streamed]) {
        expect(await refOf(chatId)).toMatchObject({ fetch_state: 'skipped', sha256: null });
        expect(await mediaOf(chatId)).toMatchObject({ state: 'skipped' });
      }
      expect((await refOf(declared.chatId)).last_error).toBe(`size ${body.length} exceeds limit ${limit}`);
      expect(await fs.readdir(path.join(root, 'tmp'))).toEqual([]); // 中途放弃的下载不留临时文件

      // 会话级策略优先于全局：给其中一个会话放宽上限后能正常下载。
      const chat = await one<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId} and peer_id = ${peers[2]!}`);
      await t.db.execute(
        sql`insert into storage_policies (account_id, scope, chat_id, auto_fetch_max_bytes) values (${acc.accountId}, 'chat', ${chat.id}, ${body.length * 2})`,
      );
      await t.db.execute(sql`update media_refs set fetch_state = 'pending' where chat_id = ${chat.id}`);
      await fetcher().runOnce();
      expect(await refOf(chat.id)).toMatchObject({ fetch_state: 'stored', sha256: sha256(body) });
    } finally {
      await t.db.execute(sql`delete from storage_policies where account_id = ${acc.accountId}`);
    }
  });

  it('retries transient failures with backoff and gives up after maxAttempts', async () => {
    const body = await png(64, 64, { r: 9, g: 9, b: 9 });
    files.set('e.png', { body, type: 'image/png' });
    const f = fetcher(new StoredUrlSource(), { maxAttempts: 3 });

    const flaky = await ingestImage(nextPeer(), 1, { url: `${base}/flaky/e.png/1` });
    expect(await f.runOnce()).toBe(1);
    const failed = await refOf(flaky.chatId);
    expect(failed).toMatchObject({ fetch_state: 'failed', attempts: 1, last_error: 'HTTP 500' });
    expect(toDate(failed.next_attempt_at)!.getTime()).toBeGreaterThan(Date.now() + 30_000); // 退避中
    expect(await mediaOf(flaky.chatId)).toMatchObject({ state: 'pending' }); // 还会重试，客户端看到的仍是"下载中"
    expect(await f.runOnce()).toBe(0); // 未到重试时间不会被认领

    await makeDue(failed.id);
    expect(await f.runOnce()).toBe(1);
    expect(await refOf(flaky.chatId)).toMatchObject({ fetch_state: 'stored', attempts: 2, sha256: sha256(body), last_error: null });

    const broken = await ingestImage(nextPeer(), 1, { url: `${base}/status/500` });
    const id = (await refOf(broken.chatId)).id;
    for (let attempt = 1; attempt <= 3; attempt++) {
      if (attempt > 1) await makeDue(id);
      expect(await f.runOnce()).toBe(1);
    }
    const gaveUp = await refOf(broken.chatId);
    expect(gaveUp).toMatchObject({ fetch_state: 'failed', attempts: 3, next_attempt_at: null });
    expect(gaveUp.last_error).toMatch(/^gave up after 3 attempts: HTTP 500/);
    expect(await mediaOf(broken.chatId)).toMatchObject({ state: 'failed' });
    expect(await f.runOnce()).toBe(0);
  });

  it('never hands the same ref to two workers, and recover() requeues refs left mid-download', async () => {
    const peers = Array.from({ length: 6 }, () => nextPeer());
    for (const [i, peer] of peers.entries()) {
      files.set(`s${i}.png`, { body: await png(32, 32, { r: i * 30, g: 0, b: 0 }), type: 'image/png' });
      await ingestImage(peer, 1, { url: `${base}/slow/s${i}.png` });
    }
    const [n1, n2] = await Promise.all([fetcher().runOnce(6), fetcher().runOnce(6)]);
    expect(n1 + n2).toBe(6);
    for (let i = 0; i < 6; i++) expect(hits.get(`/slow/s${i}.png`)).toBe(1);

    const body = await png(16, 16, { r: 0, g: 0, b: 255 });
    files.set('f.png', { body, type: 'image/png' });
    const crashed = await ingestImage(nextPeer(), 1, { url: `${base}/file/f.png` });
    await t.db.execute(sql`update media_refs set fetch_state = 'fetching', attempts = 1 where chat_id = ${crashed.chatId}`);
    const f = fetcher();
    expect(await f.runOnce()).toBe(0);
    expect(await f.recover()).toBe(1);
    expect(await f.runOnce()).toBe(1);
    expect(await refOf(crashed.chatId)).toMatchObject({ fetch_state: 'stored', attempts: 2 });
  });

  it('fetches media of the chat being viewed first, then the newest', async () => {
    const peers = [nextPeer(), nextPeer(), nextPeer()];
    const chats: number[] = [];
    for (const [i, peer] of peers.entries()) {
      files.set(`p${i}.png`, { body: await png(8, 8, { r: 0, g: i * 80, b: 0 }), type: 'image/png' });
      chats.push((await ingestImage(peer, 1, { url: `${base}/file/p${i}.png` })).chatId);
    }
    let viewing: number[] = [chats[0]!];
    const f = fetcher(new StoredUrlSource(), { priorityChatIds: () => viewing });
    expect(await f.runOnce(1)).toBe(1);
    expect((await refOf(chats[0]!)).fetch_state).toBe('stored'); // 正在看的会话最先（虽然它最旧）

    viewing = [];
    expect(await f.runOnce(1)).toBe(1);
    expect((await refOf(chats[2]!)).fetch_state).toBe('stored'); // 其余的新的优先
    expect((await refOf(chats[1]!)).fetch_state).toBe('pending');
    expect(await f.runOnce(1)).toBe(1);
    expect((await refOf(chats[1]!)).fetch_state).toBe('stored');
  });

  it('asks the upstream for a link by locator (history media), and waits without burning attempts while it is offline', async () => {
    const body = await png(40, 30, { r: 120, g: 0, b: 120 });
    files.set('h.png', { body, type: 'image/png' });
    const locator = { chatType: 2, peerUid: '700100', msgId: '7400000000000000123', elementId: '7000000000000000456', elementType: 2 };
    let online = false;
    const calls: unknown[] = [];
    const hub = {
      isConnected: () => online,
      call: async <T,>(_qq: number, action: string, params: unknown): Promise<T> => {
        calls.push({ action, params });
        return { url: `${base}/file/h.png` } as T;
      },
    };
    const f = fetcher(new NapcatMediaSource(t.db, hub), { offlineRetryMs: 30_000 });
    const { chatId } = await ingestImage(nextPeer(), 1, { locator }); // 历史消息：没有现成链接
    // 图片原图是按需的：像看大图时那样要原图（QQ 缩略图那条这里不测）。
    await t.db.execute(sql`delete from media_refs where chat_id = ${chatId} and role = 'qq_thumb'`);
    await ingest.requestMedia(acc.accountId, [{ chatId, seq: 1, ord: 0 }], 'original');

    expect(await f.runOnce()).toBe(1);
    const waiting = await refOf(chatId);
    expect(waiting).toMatchObject({ fetch_state: 'failed', attempts: 0 }); // 不消耗重试次数
    expect(waiting.last_error).toMatch(/offline/);
    expect(toDate(waiting.next_attempt_at)!.getTime()).toBeGreaterThan(Date.now() + 20_000);
    expect(await mediaOf(chatId)).toMatchObject({ state: 'pending' });
    expect(calls).toEqual([]);

    online = true;
    await makeDue(waiting.id);
    expect(await f.runOnce()).toBe(1);
    expect(await refOf(chatId)).toMatchObject({ fetch_state: 'stored', sha256: sha256(body), attempts: 1 });
    expect(calls).toEqual([{ action: 'x.media_url', params: locator }]);
  });

  it('runs in the background until stopped', async () => {
    const body = await png(48, 48, { r: 0, g: 255, b: 0 });
    files.set('g.png', { body, type: 'image/png' });
    const f = fetcher();
    f.start();
    try {
      const { chatId } = await ingestImage(nextPeer(), 1, { url: `${base}/file/g.png` });
      f.poke();
      await expect.poll(async () => (await refOf(chatId)).fetch_state, { timeout: 5_000, interval: 20 }).toBe('stored');
    } finally {
      const started = Date.now();
      await f.stop();
      expect(Date.now() - started).toBeLessThan(1_000);
    }
    const leftover = await maybeOne(t.db, sql`select id from media_refs where fetch_state in ('pending', 'fetching')`);
    expect(leftover).toBeNull();
  });
});
