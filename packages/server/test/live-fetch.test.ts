// 边下边播 + 索引在末尾的视频（2026-11-08）：下载时另用 Range 先取回末尾的 moov，
// 播放器在主下载还远没到末尾时就能读到它。用一个限速、支持 Range 的假 QQ 服务器测。
import fs from 'node:fs/promises';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { MediaFetcher } from '../src/media/fetcher.ts';
import { LiveDownloads } from '../src/media/live.ts';
import { MediaService } from '../src/media/service.ts';
import { StoredUrlSource } from '../src/media/source.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
let server: http.Server;
let base: string;
let sentMain = 0;

const box = (size: number, type: string, fill = 0) => {
  const b = Buffer.alloc(size, fill);
  b.writeUInt32BE(size, 0);
  b.write(type, 4, 'latin1');
  return b;
};
// ftyp + 2 MB 的 mdat + moov：索引在末尾。
const video = Buffer.concat([box(24, 'ftyp'), box(2 * 1024 * 1024, 'mdat', 7), box(4096, 'moov', 9)]);
const moovStart = 24 + 2 * 1024 * 1024;

beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-live-'));
  server = http.createServer((req, res) => {
    const range = /bytes=(\d+)-/.exec(req.headers.range ?? '');
    if (range) {
      const from = Number(range[1]);
      res.writeHead(206, { 'content-type': 'video/mp4', 'content-length': video.length - from, 'content-range': `bytes ${from}-${video.length - 1}/${video.length}` });
      return void res.end(video.subarray(from));
    }
    // 整段：每 20 毫秒 64 KB，约 0.7 秒下完。
    res.writeHead(200, { 'content-type': 'video/mp4', 'content-length': video.length });
    let pos = 0;
    const tick = () => {
      if (pos >= video.length) return void res.end();
      const chunk = video.subarray(pos, pos + 65536);
      pos += chunk.length;
      sentMain = pos;
      res.write(chunk);
      setTimeout(tick, 20);
    };
    tick();
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

afterAll(async () => {
  await new Promise((resolve) => server?.close(resolve));
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

describe('live video download', () => {
  it('fetches the moov at the end first so the player can start', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    await ingest.ingestMessage(acc.qqAccountId, {
      scene: 'friend', peerId: 61001, seq: 1, senderId: 61001, time: 1_800_000_001,
      segments: [{ type: 'video', media: { ord: 0, state: 'pending' } }],
      media: [{ ord: 0, kind: 'video', role: 'attachment', url: `${base}/v.mp4`, size: video.length }],
      self: false, source: 'realtime',
    });
    const media = new MediaService(t.db, new LocalFsBackend(root));
    const live = new LiveDownloads(path.join(root, 'live'));
    let liveId = '';
    const fetcher = new MediaFetcher(t.db, media, ingest, new StoredUrlSource(), {
      pollMs: 20,
      live: { downloads: live, sign: (id) => ((liveId = id), `/media/live/${id}/video.mp4`) },
    });
    const running = fetcher.runOnce();
    while (!liveId) await new Promise((r) => setTimeout(r, 5));
    const parts: Buffer[] = [];
    // 播放器按 512 KiB 对齐、从 moov 前面一点开始读。
    const from = Math.floor(moovStart / 524_288) * 524_288;
    for await (const p of live.read(liveId, from, video.length - 1)) parts.push(p as Buffer);
    expect(Buffer.concat(parts).equals(video.subarray(from))).toBe(true);
    // moov 读到时，主下载还远没到末尾。
    expect(sentMain).toBeLessThan(video.length / 2);
    await running;
    const head: Buffer[] = [];
    for await (const p of live.read(liveId, 0, 1023)) head.push(p as Buffer);
    expect(Buffer.concat(head).equals(video.subarray(0, 1024))).toBe(true);
  });
});
