// 按会话的占用统计：增量维护（在单写者事务里调用）+ 全量重算（定期校正、测试判定）。
// 定义见 @qqbridge/domain 的 computeChatStorage：逻辑占用 / 独占占用 / 共享占用 = 逻辑 - 独占。
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, type Db, type Queryable, type Tx } from '../db/client.ts';

async function ensureChatStorage(tx: Tx, chatId: number): Promise<void> {
  await tx.execute(sql`insert into chat_storage (chat_id) values (${chatId}) on conflict (chat_id) do nothing`);
}

// 口径：只统计原件还在（blobs.state = 'present'）的内容；原件被清理后不再占空间，重新下载回来再计入。
// 统计变化都先锁住 blobs 行（update / for update），与原件的清理、恢复互斥。

/** 会话里新增一处对 blob 的引用。同一会话里重复出现只在第一次计入占用。 */
export async function addUsage(tx: Tx, chatId: number, sha256: string): Promise<void> {
  const usage = await one<{ ref_count: number }>(
    tx,
    sql`insert into chat_blob_usage (chat_id, sha256, ref_count) values (${chatId}, ${sha256}, 1)
        on conflict (chat_id, sha256) do update set ref_count = chat_blob_usage.ref_count + 1
        returning ref_count`,
  );
  if (usage.ref_count > 1) return;
  const blob = await one<{ ref_chats: number; size: number; state: string }>(
    tx,
    sql`update blobs set ref_chats = ref_chats + 1 where sha256 = ${sha256} returning ref_chats, size, state`,
  );
  await ensureChatStorage(tx, chatId);
  const present = blob.state === 'present';
  const size = present ? blob.size : 0;
  await tx.execute(
    sql`update chat_storage
           set logical_bytes = logical_bytes + ${size},
               exclusive_bytes = exclusive_bytes + ${blob.ref_chats === 1 ? size : 0},
               blob_count = blob_count + ${present ? 1 : 0},
               updated_at = now()
         where chat_id = ${chatId}`,
  );
  if (blob.ref_chats === 2 && size > 0) {
    // 原来只属于另一个会话的内容变成了共享：那个会话的独占占用减少。
    await tx.execute(
      sql`update chat_storage set exclusive_bytes = exclusive_bytes - ${size}, updated_at = now()
           where chat_id = (select chat_id from chat_blob_usage where sha256 = ${sha256} and chat_id <> ${chatId} limit 1)`,
    );
  }
}

/**
 * 原件被清理（present = false）或重新下载回来（present = true）：所有引用它的会话的占用随之变化。
 * 状态没变时什么也不做；返回是否发生了变化。
 */
export async function setBlobPresence(tx: Tx, sha256: string, present: boolean): Promise<boolean> {
  const blob = await maybeOne<{ ref_chats: number; size: number; state: string }>(
    tx,
    sql`select ref_chats, size, state from blobs where sha256 = ${sha256} for update`,
  );
  if (!blob || (blob.state === 'present') === present) return false;
  await tx.execute(sql`update blobs set state = ${present ? 'present' : 'purged'} where sha256 = ${sha256}`);
  const sign = present ? 1 : -1;
  await tx.execute(
    sql`update chat_storage s
           set logical_bytes = logical_bytes + ${sign * blob.size},
               exclusive_bytes = exclusive_bytes + ${blob.ref_chats === 1 ? sign * blob.size : 0},
               blob_count = blob_count + ${sign},
               updated_at = now()
          from chat_blob_usage u
         where u.sha256 = ${sha256} and s.chat_id = u.chat_id`,
  );
  return true;
}

/** 会话里移除一处引用；最后一处移除时扣减占用。 */
export async function removeUsage(tx: Tx, chatId: number, sha256: string): Promise<void> {
  const usage = await maybeOne<{ ref_count: number }>(
    tx,
    sql`update chat_blob_usage set ref_count = ref_count - 1
         where chat_id = ${chatId} and sha256 = ${sha256} returning ref_count`,
  );
  if (!usage || usage.ref_count > 0) return;
  await tx.execute(sql`delete from chat_blob_usage where chat_id = ${chatId} and sha256 = ${sha256}`);
  const blob = await one<{ ref_chats: number; size: number; state: string }>(
    tx,
    sql`update blobs set ref_chats = ref_chats - 1 where sha256 = ${sha256} returning ref_chats, size, state`,
  );
  const present = blob.state === 'present';
  const size = present ? blob.size : 0;
  const wasExclusive = blob.ref_chats === 0;
  await tx.execute(
    sql`update chat_storage
           set logical_bytes = logical_bytes - ${size},
               exclusive_bytes = exclusive_bytes - ${wasExclusive ? size : 0},
               blob_count = blob_count - ${present ? 1 : 0},
               updated_at = now()
         where chat_id = ${chatId}`,
  );
  if (blob.ref_chats === 1 && size > 0) {
    // 只剩一个会话引用：它变成独占。
    await tx.execute(
      sql`update chat_storage set exclusive_bytes = exclusive_bytes + ${size}, updated_at = now()
           where chat_id = (select chat_id from chat_blob_usage where sha256 = ${sha256} limit 1)`,
    );
  }
}

/**
 * 全量重算：从 media_refs 重建 chat_blob_usage、blobs.ref_chats、chat_storage。
 * 返回被修正的行数（正常情况下应为 0；非 0 说明增量维护有偏差）。
 */
export async function recomputeStorage(db: Db): Promise<{ corrected: number }> {
  return db.transaction(async (tx) => {
    let corrected = 0;
    const count = (r: { rowCount?: number | null }) => (corrected += r.rowCount ?? 0);

    count(
      await tx.execute(sql`
        with expected as (
          select chat_id, sha256, count(*)::int as n from media_refs where sha256 is not null group by chat_id, sha256
        )
        insert into chat_blob_usage (chat_id, sha256, ref_count)
        select chat_id, sha256, n from expected
        on conflict (chat_id, sha256) do update set ref_count = excluded.ref_count
        where chat_blob_usage.ref_count <> excluded.ref_count`),
    );
    count(
      await tx.execute(sql`
        delete from chat_blob_usage u
         where not exists (select 1 from media_refs r where r.chat_id = u.chat_id and r.sha256 = u.sha256)`),
    );
    count(
      await tx.execute(sql`
        update blobs b set ref_chats = (select count(*)::int from chat_blob_usage u where u.sha256 = b.sha256)
         where b.ref_chats <> (select count(*)::int from chat_blob_usage u where u.sha256 = b.sha256)`),
    );
    count(
      await tx.execute(sql`
        with agg as (
          select u.chat_id,
                 sum(b.size)::bigint as logical,
                 sum(case when b.ref_chats = 1 then b.size else 0 end)::bigint as exclusive,
                 count(*)::int as cnt
            from chat_blob_usage u join blobs b on b.sha256 = u.sha256
           where b.state = 'present'
           group by u.chat_id
        ), target as (
          -- 没有统计行的会话等同于全 0：只有算出来不为 0 时才补行。
          select c.id as chat_id, coalesce(a.logical, 0) as logical, coalesce(a.exclusive, 0) as exclusive, coalesce(a.cnt, 0) as cnt
            from chats c left join agg a on a.chat_id = c.id
           where a.chat_id is not null or exists (select 1 from chat_storage s where s.chat_id = c.id)
        )
        insert into chat_storage (chat_id, logical_bytes, exclusive_bytes, blob_count)
        select chat_id, logical, exclusive, cnt from target
        on conflict (chat_id) do update
           set logical_bytes = excluded.logical_bytes,
               exclusive_bytes = excluded.exclusive_bytes,
               blob_count = excluded.blob_count,
               updated_at = now()
         where chat_storage.logical_bytes <> excluded.logical_bytes
            or chat_storage.exclusive_bytes <> excluded.exclusive_bytes
            or chat_storage.blob_count <> excluded.blob_count`),
    );
    return { corrected };
  });
}

/**
 * 下载前去重：QQ 消息元素里给的 md5 命中已有内容就直接复用，不再下载。
 * partial = true 表示只有前 10 MiB 的 md5（大文件），此时必须同时比对大小。
 */
export interface ReusableBlob {
  sha256: string;
  size: number;
  mime: string | null;
  /** 之前处理时生成的派生信息（图片才有）。 */
  thumbhash: string | null;
  width: number | null;
  height: number | null;
  thumbSha256: string | null;
  previewSha256: string | null;
  playableSha256: string | null;
  waveform: string | null;
}

export async function findReusableBlob(
  db: Queryable,
  qqMd5: string,
  size: number | undefined,
  partial: boolean,
): Promise<ReusableBlob | null> {
  const md5 = qqMd5.toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(md5)) return null;
  if (partial && size === undefined) return null;
  const match = partial
    ? sql`b.md5_head = ${md5} and b.size = ${size ?? null}::bigint`
    : sql`b.md5 = ${md5} and (${size ?? null}::bigint is null or b.size = ${size ?? null}::bigint)`;
  const row = await maybeOne<{
    sha256: string;
    size: number;
    mime: string | null;
    thumbhash: string | null;
    width: number | null;
    height: number | null;
    thumb_sha256: string | null;
    preview_sha256: string | null;
    playable_sha256: string | null;
    waveform: string | null;
  }>(
    db,
    sql`select b.sha256, b.size, b.mime, b.thumbhash, b.width, b.height, b.waveform,
               (select v.variant_sha256 from blob_variants v where v.sha256 = b.sha256 and v.variant = 'thumb') as thumb_sha256,
               (select v.variant_sha256 from blob_variants v where v.sha256 = b.sha256 and v.variant = 'preview') as preview_sha256,
               (select v.variant_sha256 from blob_variants v where v.sha256 = b.sha256 and v.variant = 'playable') as playable_sha256
          from blobs b
         where ${match} and b.state = 'present'
         limit 1`,
  );
  if (!row) return null;
  return {
    sha256: row.sha256,
    size: row.size,
    mime: row.mime,
    thumbhash: row.thumbhash,
    width: row.width,
    height: row.height,
    thumbSha256: row.thumb_sha256,
    previewSha256: row.preview_sha256,
    playableSha256: row.playable_sha256,
    waveform: row.waveform,
  };
}

/** 复用已有内容时，消息里该媒体段要带上的信息。 */
export function reusedMediaPatch(hit: ReusableBlob) {
  return {
    state: 'stored' as const,
    sha256: hit.sha256,
    size: hit.size,
    ...(hit.mime ? { mime: hit.mime } : {}),
    ...(hit.thumbhash ? { thumbhash: hit.thumbhash } : {}),
    ...(hit.thumbSha256 ? { thumbSha256: hit.thumbSha256 } : {}),
    ...(hit.previewSha256 ? { previewSha256: hit.previewSha256 } : {}),
    ...(hit.width ? { width: hit.width } : {}),
    ...(hit.height ? { height: hit.height } : {}),
    ...(hit.playableSha256 ? { playableSha256: hit.playableSha256 } : {}),
    ...(hit.waveform ? { waveform: hit.waveform } : {}),
  };
}

export interface StorageRow {
  chatId: number;
  logicalBytes: number;
  exclusiveBytes: number;
  blobCount: number;
}

export async function chatStorageRows(db: Queryable, chatIds?: readonly number[]): Promise<StorageRow[]> {
  const list = await rows<{ chat_id: number; logical_bytes: number; exclusive_bytes: number; blob_count: number }>(
    db,
    chatIds && chatIds.length > 0
      ? sql`select chat_id, logical_bytes, exclusive_bytes, blob_count from chat_storage where chat_id in (${sql.join(
          chatIds.map((id) => sql`${id}`),
          sql`, `,
        )})`
      : sql`select chat_id, logical_bytes, exclusive_bytes, blob_count from chat_storage`,
  );
  return list.map((r) => ({
    chatId: r.chat_id,
    logicalBytes: r.logical_bytes,
    exclusiveBytes: r.exclusive_bytes,
    blobCount: r.blob_count,
  }));
}
