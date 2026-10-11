// 发起会话（联系人页"发消息"）与存储页的分类统计。
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import type { Update } from '../src/sync/rows.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-open-chat-'));
});
afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

describe('openChat', () => {
  it('creates the chat once and pushes it to devices; later calls return the same id', async () => {
    const { ingest, bus } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const updates: Update[] = [];
    bus.subscribe(acc.accountId, (u) => updates.push(u));
    const id = await ingest.openChat(acc.accountId, 'friend', 50001);
    expect(updates.filter((u) => u.type === 'dialog')).toHaveLength(1);
    expect(await ingest.openChat(acc.accountId, 'friend', 50001)).toBe(id);
    expect(updates.filter((u) => u.type === 'dialog')).toHaveLength(1);
    expect(await ingest.openChat(acc.accountId, 'group', 50001)).not.toBe(id);
  });
});

describe('storage categories', () => {
  it('splits stored content by what it is used for, counting each blob once', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const media = new MediaService(t.db, new LocalFsBackend(root));
    const store = async (text: string, kind: string) => (await media.storeBlob(Readable.from([Buffer.from(text)]), { kind })).sha256;
    const chatId = await ingest.openChat(acc.accountId, 'group', 60001);
    const photo = await store('photo', 'image');
    const thumb = await store('thumb', 'image');
    const avatar = await store('avatar', 'image');
    const derived = await store('derived', 'image');
    const ref = (sha: string, role: string, kind: string, seq: number) =>
      t.db.execute(sql`insert into media_refs (chat_id, message_seq, ordinal, role, kind, sha256, fetch_state, time)
                       values (${chatId}, ${seq}, 0, ${role}, ${kind}, ${sha}, 'stored', now())`);
    await ref(photo, 'attachment', 'image', 1);
    await ref(photo, 'attachment', 'image', 2); // 同一张图出现两次：只算一次
    await ref(thumb, 'qq_thumb', 'image', 1);
    await t.db.execute(sql`insert into peers (qq_account_id, kind, peer_id, avatar_sha256, pts) values (${acc.qqAccountId}, 'user', 1, ${avatar}, 0)`);
    await t.db.execute(sql`insert into blob_variants (sha256, variant, variant_sha256) values (${photo}, 'thumb', ${derived})`);
    const stats = Object.fromEntries((await media.storageCategories()).map((c) => [c.category, c]));
    expect(stats.image).toMatchObject({ count: 1, bytes: 5 });
    expect(stats.qq_thumb).toMatchObject({ count: 1, bytes: 5 });
    expect(stats.avatar).toMatchObject({ count: 1, bytes: 6 });
    expect(stats.derived).toMatchObject({ count: 1, bytes: 7 });
    const [hot] = await media.volumes();
    expect(hot).toMatchObject({ tier: 'hot', available: true });
    expect(hot!.totalBytes).toBeGreaterThan(hot!.freeBytes);
    expect((await one<{ n: number }>(t.db, sql`select count(*)::int as n from blobs`)).n).toBe(4);
  });
});
