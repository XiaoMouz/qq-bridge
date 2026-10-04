import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { computeChatStorage } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import fc from 'fast-check';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { maybeOne, rows, type Db } from '../src/db/client.ts';
import { chatStorageRows, recomputeStorage, removeUsage } from '../src/media/accounting.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend, MD5_HEAD_BYTES, TooLargeError } from '../src/media/store.ts';
import { getChatDifference } from '../src/sync/difference.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, imageMessage, services } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
let media: MediaService;

beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-media-'));
  media = new MediaService(t.db, new LocalFsBackend(root));
});

afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

const md5 = (b: Buffer) => createHash('md5').update(b).digest('hex');
const sha256 = (b: Buffer) => createHash('sha256').update(b).digest('hex');

describe('LocalFsBackend', () => {
  it('hashes while writing, stores each content once, and computes the 10 MiB head md5', async () => {
    const backend = new LocalFsBackend(path.join(root, 'backend'));
    const big = randomBytes(MD5_HEAD_BYTES + 12345);
    const first = await backend.put(Readable.from([big.subarray(0, 1000), big.subarray(1000)]));
    expect(first).toMatchObject({
      sha256: sha256(big),
      md5: md5(big),
      md5Head: md5(big.subarray(0, MD5_HEAD_BYTES)),
      size: big.length,
      existed: false,
    });
    const second = await backend.put(Readable.from([big]));
    expect(second.existed).toBe(true);
    const chunks: Buffer[] = [];
    for await (const chunk of await backend.open(first.key, { start: 10, end: 19 })) chunks.push(chunk as Buffer);
    expect(Buffer.concat(chunks)).toEqual(big.subarray(10, 20));
  });

  it('rejects objects over the size limit and leaves nothing behind', async () => {
    const backend = new LocalFsBackend(path.join(root, 'limited'));
    await expect(backend.put(Readable.from([randomBytes(2048)]), { maxBytes: 1024 })).rejects.toBeInstanceOf(TooLargeError);
    expect(await fs.readdir(path.join(root, 'limited', 'tmp'))).toEqual([]);
  });
});

describe('media dedupe, usages and storage accounting', () => {
  it('reuses stored content by QQ md5 before downloading and tracks where it appears', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const content = randomBytes(5000);

    // 第一处出现：还没有这份内容 → 引用待下载；下载完成后消息里的媒体状态变为 stored。
    const first = await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 1, 1, 7, { qqMd5: md5(content).toUpperCase(), size: 5000 }));
    const pending = await maybeOne<{ id: number; fetch_state: string }>(t.db, sql`select id, fetch_state from media_refs where chat_id = ${first.chatId}`);
    expect(pending?.fetch_state).toBe('pending');
    const blob = await media.storeBlob(Readable.from([content]), { kind: 'image', mime: 'image/png' });
    await ingest.mediaStored(pending!.id, blob);
    const diff = await getChatDifference(t.db, acc.accountId, first.chatId, 1);
    expect(diff.messages[0]?.segments[0]).toMatchObject({ type: 'image', media: { state: 'stored', sha256: blob.sha256, size: 5000 } });

    // 第二处出现（另一个群）：md5 命中，直接复用，不再下载。
    const second = await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 2, 1, 8, { qqMd5: md5(content), size: 5000 }));
    const reused = await maybeOne<{ fetch_state: string; sha256: string }>(t.db, sql`select fetch_state, sha256 from media_refs where chat_id = ${second.chatId}`);
    expect(reused).toEqual({ fetch_state: 'stored', sha256: blob.sha256 });

    const usages = await media.listUsages(acc.accountId, blob.sha256);
    expect(usages.map((u) => [u.peerId, u.messageSeq]).sort()).toEqual([
      [1, 1],
      [2, 1],
    ]);

    const storage = await chatStorageRows(t.db, [first.chatId, second.chatId]);
    for (const s of storage) expect(s).toMatchObject({ logicalBytes: 5000, exclusiveBytes: 0, blobCount: 1 });
    const overview = await media.storageOverview(acc.accountId);
    expect(overview).toMatchObject({ physicalBytes: 5000, logicalBytes: 10_000, dedupSavedBytes: 5000, blobCount: 1 });
  });

  it('only matches the partial (first 10 MiB) md5 together with the exact size', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const content = randomBytes(3000);
    const blob = await media.storeBlob(Readable.from([content]), { kind: 'file' });
    const wrongSize = await ingest.ingestMessage(acc.qqAccountId, imageMessage('friend', 5, 1, 5, { qqMd5: blob.md5Head, qqMd5Partial: true, size: 2999 }));
    const rightSize = await ingest.ingestMessage(acc.qqAccountId, imageMessage('friend', 5, 2, 5, { qqMd5: blob.md5Head, qqMd5Partial: true, size: 3000 }));
    const states = await rows<{ message_seq: number; fetch_state: string }>(
      t.db,
      sql`select message_seq, fetch_state from media_refs where chat_id = ${rightSize.chatId} order by message_seq`,
    );
    expect(wrongSize.chatId).toBe(rightSize.chatId);
    expect(states).toEqual([
      { message_seq: 1, fetch_state: 'pending' },
      { message_seq: 2, fetch_state: 'stored' },
    ]);
  });

  it('plans cleanup honouring the strongest retention among all chats that share the content', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const shared = await media.storeBlob(Readable.from([randomBytes(7000)]), { kind: 'image' });
    const exclusive = await media.storeBlob(Readable.from([randomBytes(3000)]), { kind: 'image' });
    const a = await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 10, 1, 7, { qqMd5: shared.md5 }, { time: 1_700_000_000 }));
    await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 10, 2, 7, { qqMd5: exclusive.md5 }, { time: 1_700_000_000 }));
    const b = await ingest.ingestMessage(acc.qqAccountId, imageMessage('group', 11, 1, 7, { qqMd5: shared.md5 }, { time: 1_700_000_000 }));

    const now = 1_800_000_000;
    const plan = await media.planCleanup(acc.accountId, a.chatId, { kinds: ['image'], olderThanDays: 30 }, now);
    // 共享的那份在另一个群（默认永久保留）里仍需要原件 → 保留；独占的那份可以删。
    expect(plan).toMatchObject({ refCount: 2, blobCount: 2, purgeableBlobCount: 1, freedBytes: 3000, keptSharedBlobCount: 1 });

    // 另一个群设为"只保留缩略图"后，共享内容也没人需要原件了。
    await t.db.execute(
      sql`insert into storage_policies (account_id, scope, chat_id, keep_original_days) values (${acc.accountId}, 'chat', ${b.chatId}, 0)`,
    );
    const plan2 = await media.planCleanup(acc.accountId, a.chatId, { kinds: ['image'], olderThanDays: 30 }, now);
    expect(plan2).toMatchObject({ purgeableBlobCount: 2, freedBytes: 10_000, keptSharedBlobCount: 0 });

    // 媒体还没到 30 天的话不在清理范围内。
    const recent = await media.planCleanup(acc.accountId, a.chatId, { olderThanDays: 30 }, 1_700_000_000 + 86_400);
    expect(recent.refCount).toBe(0);
  });
});

describe('storage accounting (property)', () => {
  it('incremental per-chat storage always equals a full recomputation', async () => {
    await fc.assert(
      fc.asyncProperty(
        fc.array(
          fc.oneof(
            fc.record({ op: fc.constant('ref' as const), chat: fc.integer({ min: 0, max: 3 }), blob: fc.integer({ min: 0, max: 4 }), viaMd5: fc.boolean() }),
            fc.record({ op: fc.constant('unref' as const), pick: fc.nat() }),
            // 原件被清理 / 同样的内容重新下载回来（恢复）。
            fc.record({ op: fc.constant('purge' as const), blob: fc.integer({ min: 0, max: 4 }) }),
            fc.record({ op: fc.constant('restore' as const), blob: fc.integer({ min: 0, max: 4 }) }),
          ),
          { minLength: 1, maxLength: 30 },
        ),
        async (ops) => {
          const { ingest } = services(t.db);
          const acc = await createTestAccount(t.db, ingest);
          const contents = [1, 2, 3, 4, 5].map((n) => randomBytes(n * 1000 + Math.floor(Math.random() * 999)));
          const blobs = await Promise.all(contents.map((c) => media.storeBlob(Readable.from([c]))));
          const seqByChat = [0, 0, 0, 0];
          for (const op of ops) {
            if (op.op === 'ref') {
              const blob = blobs[op.blob]!;
              const seq = ++seqByChat[op.chat]!;
              const res = await ingest.ingestMessage(
                acc.qqAccountId,
                imageMessage('group', 900 + op.chat, seq, 7, op.viaMd5 ? { qqMd5: blob.md5 } : {}),
              );
              if (!op.viaMd5) {
                const ref = await maybeOne<{ id: number }>(
                  t.db,
                  sql`select id from media_refs where chat_id = ${res.chatId} and message_seq = ${seq}`,
                );
                await ingest.mediaStored(ref!.id, blob);
              }
            } else if (op.op === 'purge') {
              await media.purgeOriginal(blobs[op.blob]!.sha256);
            } else if (op.op === 'restore') {
              await media.storeBlob(Readable.from([contents[op.blob]!]));
            } else {
              const refs = await rows<{ id: number }>(
                t.db,
                sql`select r.id from media_refs r join chats c on c.id = r.chat_id
                     where c.qq_account_id = ${acc.qqAccountId} and r.sha256 is not null order by r.id`,
              );
              if (refs.length === 0) continue;
              await deleteRef(t.db, refs[op.pick % refs.length]!.id);
            }
          }

          const usages = await rows<{ chat_id: number; sha256: string; size: number }>(
            t.db,
            sql`select r.chat_id, r.sha256, b.size from media_refs r join blobs b on b.sha256 = r.sha256
                 join chats c on c.id = r.chat_id where c.qq_account_id = ${acc.qqAccountId}`,
          );
          // 判定基准：@qqbridge/domain 的全量定义。注意 blob 可能也被其他测试账号引用，所以用全库的引用关系计算。
          const allUsages = await rows<{ chat_id: number; sha256: string; size: number; state: string }>(
            t.db,
            sql`select r.chat_id, r.sha256, b.size, b.state from media_refs r join blobs b on b.sha256 = r.sha256`,
          );
          const expected = computeChatStorage(
            allUsages.map((u) => ({ chatId: u.chat_id, sha256: u.sha256, size: u.size, present: u.state === 'present' })),
          );
          // 本账号的所有会话都要核对（包括引用已被删光的会话）。
          const chatIds = (
            await rows<{ id: number }>(t.db, sql`select id from chats where qq_account_id = ${acc.qqAccountId}`)
          ).map((c) => c.id);
          void usages;
          const actual = chatIds.length === 0 ? [] : await chatStorageRows(t.db, chatIds);
          for (const row of actual) {
            const e = expected.get(row.chatId) ?? { logicalBytes: 0, exclusiveBytes: 0, blobCount: 0 };
            expect({ chatId: row.chatId, ...e }).toEqual(row);
          }
        },
      ),
      { numRuns: Number(process.env.PROPERTY_RUNS ?? 25) },
    );
    // 增量维护全程正确的话，全量校正不应修正任何一行。
    expect(await recomputeStorage(t.db)).toEqual({ corrected: 0 });
  });
});

/** 模拟以后的"删除消息/引用"：删引用并扣减占用（同一事务）。 */
async function deleteRef(db: Db, refId: number): Promise<void> {
  await db.transaction(async (tx) => {
    const ref = await maybeOne<{ chat_id: number; sha256: string | null }>(
      tx,
      sql`delete from media_refs where id = ${refId} returning chat_id, sha256`,
    );
    if (ref?.sha256) await removeUsage(tx, ref.chat_id, ref.sha256);
  });
}
