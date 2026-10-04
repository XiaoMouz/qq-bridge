// 冷存储在外接硬盘上：盘不在时不下沉、不往系统盘写；读到冷存储里的内容从 QQ 取回放进热存储，拿不到就是过期；
// 盘回来后清掉盘上的孤儿文件。
import fs from 'node:fs/promises';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { MediaFetcher } from '../src/media/fetcher.ts';
import { MediaService } from '../src/media/service.ts';
import { StoredUrlSource, SourceUnavailableError } from '../src/media/source.ts';
import { LocalFsBackend, RemovableBackend, STORAGE_MARKER, StorageUnavailableError } from '../src/media/store.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, imageMessage, services } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
let server: http.Server;
let base: string;
const files = new Map<string, Buffer>();

beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-coldoff-'));
  server = http.createServer((req, res) => {
    const body = files.get((req.url ?? '').slice(1));
    if (!body) return void res.writeHead(404).end();
    res.writeHead(200, { 'content-length': body.length }).end(body);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
afterAll(async () => {
  server?.close();
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

const read = async (media: MediaService, sha256: string) => {
  const chunks: Buffer[] = [];
  for await (const c of await media.openBlob((await media.getBlob(sha256))!)) chunks.push(c as Buffer);
  return Buffer.concat(chunks);
};
const tierOf = async (sha256: string) => (await one<{ tier: string }>(t.db, sql`select tier from blobs where sha256 = ${sha256}`)).tier;

describe('cold storage on a removable disk', () => {
  it('never writes to the mount point while the disk is gone', async () => {
    const mount = path.join(root, 'not-mounted');
    const cold = new RemovableBackend(mount);
    expect(cold.available()).toBe(false);
    await expect(cold.put(Readable.from([Buffer.from('x')]))).rejects.toBeInstanceOf(StorageUnavailableError);
    await expect(fs.stat(mount)).rejects.toThrow(); // 目录都没建
    expect(cold.localPath('ab/cd/x')).toBeNull();
  });

  it('restores from QQ while the disk is unplugged, reports expired when QQ has nothing, and cleans up when it is back', async () => {
    const coldRoot = path.join(root, 'hdd');
    await fs.mkdir(coldRoot, { recursive: true });
    await fs.writeFile(path.join(coldRoot, STORAGE_MARKER), '');
    const media = new MediaService(t.db, new LocalFsBackend(path.join(root, 'hot')), new RemovableBackend(coldRoot));
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);

    const data = Buffer.alloc(4096, 'cold-content');
    const blob = await media.storeBlob(Readable.from([data]), { kind: 'image' });
    await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 980001, 1, 20002, { qqMd5: blob.md5, size: data.length }));
    expect(await media.moveTier(blob.sha256, 'cold')).toBe(data.length);
    expect(await tierOf(blob.sha256)).toBe('cold');

    // 拔盘：读不到、也搬不动。
    await fs.rename(path.join(coldRoot, STORAGE_MARKER), path.join(coldRoot, 'marker.off'));
    expect(media.coldAvailable).toBe(false);
    await expect(read(media, blob.sha256)).rejects.toBeInstanceOf(StorageUnavailableError);
    expect(await media.moveTier(blob.sha256, 'hot')).toBe(0);

    // QQ 也拿不到：过期；QQ 不在线：暂时不可用。
    let refresher: () => Promise<string | null> = async () => null;
    const fetcher = new MediaFetcher(t.db, media, ingest, new StoredUrlSource(() => refresher()), {});
    expect(await fetcher.rehydrate(blob.sha256)).toBe('expired');
    refresher = async () => {
      throw new SourceUnavailableError('offline');
    };
    expect(await fetcher.rehydrate(blob.sha256)).toBe('unavailable');

    // QQ 能给：取回放进热存储，照常能读。
    files.set('pic', data);
    refresher = async () => `${base}/pic`;
    const [a, b] = await Promise.all([fetcher.rehydrate(blob.sha256), fetcher.rehydrate(blob.sha256)]);
    expect([a, b]).toEqual(['restored', 'restored']);
    expect(await tierOf(blob.sha256)).toBe('hot');
    expect(await read(media, blob.sha256)).toEqual(data);

    // 插回盘：盘上的旧文件成了孤儿，清掉。
    await fs.rename(path.join(coldRoot, 'marker.off'), path.join(coldRoot, STORAGE_MARKER));
    expect(await media.sweepColdOrphans(0)).toBe(1);
    expect(await media.sweepColdOrphans(0)).toBe(0);
  });
});
