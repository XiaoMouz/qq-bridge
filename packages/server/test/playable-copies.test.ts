// 以前给视频另存的 faststart 副本：改成直接播原件后清掉，原件不动。
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { dropPlayableCopies } from '../src/media/reprocess.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { services } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-copies-'));
});
afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

describe('dropPlayableCopies', () => {
  it('points playback back at the original and deletes only the copy', async () => {
    const media = new MediaService(t.db, new LocalFsBackend(root));
    const { ingest } = services(t.db);
    const original = await media.storeBlob(Readable.from([Buffer.from('original video bytes')]), { kind: 'video', mime: 'video/mp4' });
    const copy = await media.storeBlob(Readable.from([Buffer.from('remuxed copy of the video')]), { kind: 'video', mime: 'video/mp4' });
    await t.db.execute(sql`insert into blob_variants (sha256, variant, variant_sha256) values (${original.sha256}, 'playable', ${copy.sha256})`);

    const report = await dropPlayableCopies({ db: t.db, media, ingest });
    expect(report).toMatchObject({ videos: 1, purged: 1, skipped: 0, freedBytes: copy.size });

    const variant = await one<{ v: string }>(t.db, sql`select variant_sha256 as v from blob_variants where sha256 = ${original.sha256} and variant = 'playable'`);
    expect(variant.v).toBe(original.sha256);
    expect((await media.getBlob(original.sha256))?.state).toBe('present');
    expect((await media.getBlob(copy.sha256))?.state).not.toBe('present');

    // 再跑一遍什么也不做。
    expect(await dropPlayableCopies({ db: t.db, media, ingest })).toMatchObject({ videos: 0, purged: 0 });
  });
});
