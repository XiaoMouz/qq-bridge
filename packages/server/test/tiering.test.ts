// 冷热分层：按时间 / 会话配额 / 全局配额下沉，"永不下沉"优先，访问多次提回热存储，冷存储里的内容照常读取、重复下载不多存一份。
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { one } from '../src/db/client.ts';
import { setPolicy } from '../src/media/policies.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { PROMOTE_AFTER_ACCESSES, TierManager } from '../src/media/tiering.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, imageMessage, services, type TestAccount } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-tier-'));
});
afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

let n = 0;
async function setup() {
  n += 1;
  const media = new MediaService(t.db, new LocalFsBackend(path.join(root, `hot${n}`)), new LocalFsBackend(path.join(root, `cold${n}`)));
  const { ingest } = services(t.db);
  const acc = await createTestAccount(t.db, ingest);
  return { media, ingest, acc, tiers: new TierManager(t.db, media) };
}

/** 在会话里放一个 size 字节的原件，last access 设成 daysAgo 天前。 */
async function attach(ctx: Awaited<ReturnType<typeof setup>>, peer: number, seq: number, size: number, daysAgo: number) {
  const data = Buffer.alloc(size, `${peer}-${seq}-${n}`);
  const blob = await ctx.media.storeBlob(Readable.from([data]), { kind: 'file' });
  await ctx.ingest.ingestMessage(ctx.acc.qqAccountId, imageMessage('group', peer, seq, 20002, { qqMd5: blob.md5, size }));
  await t.db.execute(sql`update blobs set last_access_at = now() - make_interval(days => ${daysAgo}) where sha256 = ${blob.sha256}`);
  return blob.sha256;
}

const tierOf = async (sha256: string) => (await one<{ tier: string }>(t.db, sql`select tier from blobs where sha256 = ${sha256}`)).tier;
const chatOf = async (acc: TestAccount, peer: number) =>
  (await one<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId} and peer_id = ${peer}`)).id;

describe('cold storage tiering', () => {
  it('moves old, large originals to cold storage and keeps serving them', async () => {
    const ctx = await setup();
    const old = await attach(ctx, 960001, 1, 2 * 1024 * 1024, 200);
    const recent = await attach(ctx, 960001, 2, 2 * 1024 * 1024, 10);
    const small = await attach(ctx, 960001, 3, 10 * 1024, 400); // 小于默认 1 MiB 门槛

    const plan = await ctx.tiers.run(ctx.acc.accountId, true);
    expect(plan).toMatchObject({ candidates: 1, moved: 0, byReason: { age: 1 } });
    expect(await tierOf(old)).toBe('hot');

    const report = await ctx.tiers.run(ctx.acc.accountId, false);
    expect(report).toMatchObject({ moved: 1, movedBytes: 2 * 1024 * 1024 });
    expect([await tierOf(old), await tierOf(recent), await tierOf(small)]).toEqual(['cold', 'hot', 'hot']);

    // 冷存储里的照常能读；同样内容再下载一次不会在热存储里多存一份。
    const blob = (await ctx.media.getBlob(old))!;
    const chunks: Buffer[] = [];
    for await (const c of await ctx.media.openBlob(blob, { start: 0, end: 3 })) chunks.push(c as Buffer);
    expect(Buffer.concat(chunks)).toHaveLength(4);
    const again = await ctx.media.storeBlob(Readable.from([Buffer.alloc(2 * 1024 * 1024, `960001-1-${n}`)]), {});
    expect(again).toMatchObject({ sha256: old, tier: 'cold', existed: true });
    expect(ctx.media.localPath(blob)).toContain(`cold${n}`);
  });

  it('never moves what any referencing chat wants to keep hot, and honours quotas', async () => {
    const ctx = await setup();
    const keptHot = await attach(ctx, 960002, 1, 2 * 1024 * 1024, 400);
    await setPolicy(t.db, ctx.acc.accountId, { scope: 'chat', scene: null, chatId: await chatOf(ctx.acc, 960002), keepOriginalDays: null, autoFetchMaxBytes: null, coldAfterDays: -1 });
    // 同一内容也出现在另一个会话：只要有一个会话说"永不下沉"就不动。
    await ctx.ingest.ingestMessage(ctx.acc.qqAccountId, imageMessage('group', 960003, 1, 20002, { qqMd5: (await ctx.media.getBlob(keptHot))!.md5, size: 2 * 1024 * 1024 }));

    // 会话配额：960004 独占 3 个 200KiB 的原件，配额 300KiB → 最久没访问的 2 个下沉。
    const a = await attach(ctx, 960004, 1, 200 * 1024, 3);
    const b = await attach(ctx, 960004, 2, 200 * 1024, 2);
    const c = await attach(ctx, 960004, 3, 200 * 1024, 1);
    await setPolicy(t.db, ctx.acc.accountId, { scope: 'chat', scene: null, chatId: await chatOf(ctx.acc, 960004), keepOriginalDays: null, autoFetchMaxBytes: null, hotQuotaBytes: 300 * 1024 });

    const report = await ctx.tiers.run(ctx.acc.accountId, false);
    expect(report.byReason).toEqual({ age: 0, chat_quota: 2, global_quota: 0 });
    expect([await tierOf(keptHot), await tierOf(a), await tierOf(b), await tierOf(c)]).toEqual(['hot', 'cold', 'cold', 'hot']);

    // 全局配额：账号热存储超过 1 MiB → 除"永不下沉"的以外，按最久没访问继续下沉。
    await setPolicy(t.db, ctx.acc.accountId, { scope: 'global', scene: null, chatId: null, keepOriginalDays: null, autoFetchMaxBytes: null, hotQuotaBytes: 1024 * 1024 });
    const global = await ctx.tiers.run(ctx.acc.accountId, false);
    expect(global.byReason.global_quota).toBe(1);
    expect([await tierOf(keptHot), await tierOf(c)]).toEqual(['hot', 'cold']);
  });

  it('promotes originals back to hot storage after repeated access', async () => {
    const ctx = await setup();
    const sha = await attach(ctx, 960005, 1, 2 * 1024 * 1024, 400);
    await ctx.tiers.run(ctx.acc.accountId, false);
    expect(await tierOf(sha)).toBe('cold');
    for (let i = 0; i < PROMOTE_AFTER_ACCESSES; i++) {
      await t.db.execute(sql`update blobs set last_access_at = null where sha256 = ${sha}`); // 跳过 10 分钟的去重
      ctx.tiers.onAccess(sha);
      await vi.waitFor(async () => expect((await one<{ access_count: number }>(t.db, sql`select access_count from blobs where sha256 = ${sha}`)).access_count).toBeGreaterThanOrEqual(i + 1 === PROMOTE_AFTER_ACCESSES ? 0 : i + 1));
    }
    await vi.waitFor(async () => expect(await tierOf(sha)).toBe('hot'));
  });

  it('breaks a chat down by kind and tier, with the largest items first', async () => {
    const ctx = await setup();
    const big = await attach(ctx, 960006, 1, 3 * 1024 * 1024, 400);
    await attach(ctx, 960006, 2, 100 * 1024, 1);
    await ctx.tiers.run(ctx.acc.accountId, false);
    const detail = await ctx.media.chatStorage(ctx.acc.accountId, await chatOf(ctx.acc, 960006), 5);
    expect(detail.summary).toMatchObject({ hotBytes: 100 * 1024, coldBytes: 3 * 1024 * 1024 });
    expect(detail.kinds).toEqual([expect.objectContaining({ kind: 'image', count: 2, coldBytes: 3 * 1024 * 1024, purgedCount: 0 })]);
    expect(detail.largest[0]).toMatchObject({ sha256: big, tier: 'cold', shared: false, firstSeq: 1 });
  });
});
