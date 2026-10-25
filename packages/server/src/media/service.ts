// 媒体服务：存入内容（去重）、查询出处（"出现在 N 个聊天"）、存储统计、清理预估（docs/design.md 4.6）。
import fs from 'node:fs/promises';
import type { Readable } from 'node:stream';
import { originalPurgeable, resolveRule, type MediaKind, type RefRetention, type Scene } from '@qqbridge/domain';
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, toDate, type Db } from '../db/client.ts';
import { NotFoundError } from '../sync/difference.ts';
import { setBlobPresence } from './accounting.ts';
import { retentionPolicies } from './policies.ts';
import { chooseMime, SNIFF_BYTES, sniffMime } from './sniff.ts';
import { keyForSha256, type RemovableBackend, type StorageBackend } from './store.ts';

export interface BlobRecord {
  sha256: string;
  md5: string;
  md5Head: string;
  size: number;
  mime: string | null;
  kind: string | null;
  state: 'present' | 'purged';
  storageKey: string;
  /** 原件在哪一层：hot（MEDIA_ROOT）或 cold（MEDIA_COLD_ROOT）。 */
  tier: Tier;
}

export type Tier = 'hot' | 'cold';

export interface MediaUsage {
  chatId: number;
  scene: Scene;
  peerId: number;
  messageSeq: number | null;
  forwardBundleId: string | null;
  nodePath: number[] | null;
  senderUin: number | null;
  time: Date;
  role: string;
  kind: string;
}

export interface StorageOverview {
  /** 账号引用到的不同内容的实际字节数（去重后）。 */
  physicalBytes: number;
  /** 各会话逻辑占用之和（不去重时会占用的空间）。 */
  logicalBytes: number;
  /** 去重省下的空间。 */
  dedupSavedBytes: number;
  blobCount: number;
  hotBytes: number;
  coldBytes: number;
  chats: ChatStorageSummary[];
}

export interface StorageCategoryStat {
  /** image / qq_thumb / sticker / video / record / file / group_file / avatar / derived / other。 */
  category: string;
  bytes: number;
  count: number;
}

export interface StorageVolumeStat {
  tier: 'hot' | 'cold';
  available: boolean;
  totalBytes: number;
  freeBytes: number;
}

export interface ChatStorageSummary {
  chatId: number;
  scene: Scene;
  peerId: number;
  logicalBytes: number;
  exclusiveBytes: number;
  blobCount: number;
  hotBytes: number;
  coldBytes: number;
}

export interface ChatStorageDetail {
  summary: ChatStorageSummary;
  kinds: { kind: string; count: number; logicalBytes: number; exclusiveBytes: number; hotBytes: number; coldBytes: number; purgedCount: number }[];
  largest: { sha256: string; size: number; kind: string; tier: 'hot' | 'cold' | 'purged'; shared: boolean; lastAccessAt: Date | null; firstSeq: number | null }[];
}

export interface CleanupCriteria {
  kinds?: MediaKind[];
  /** 只清理多少天以前出现的媒体。 */
  olderThanDays?: number;
}

export interface CleanupPlan {
  refCount: number;
  blobCount: number;
  /** 执行后原件可以被删除的内容数（所有引用方都不再需要原件）。 */
  purgeableBlobCount: number;
  /** 预计释放的字节数：只算真正能删除的原件。 */
  freedBytes: number;
  /** 因为其他会话仍需要原件而保留下来的内容数。 */
  keptSharedBlobCount: number;
  candidateRefIds: number[];
}

async function readHead(file: string): Promise<Buffer> {
  const handle = await fs.open(file, 'r');
  try {
    const buffer = Buffer.alloc(SNIFF_BYTES);
    const { bytesRead } = await handle.read(buffer, 0, SNIFF_BYTES, 0);
    return buffer.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

export class MediaService {
  constructor(
    private readonly db: Db,
    private readonly backend: StorageBackend,
    /** 冷存储（廉价大硬盘等）；没配置时所有内容都在热存储。接口与热存储相同，以后换成 S3 一类也只需实现 StorageBackend。 */
    private readonly cold: StorageBackend | null = null,
  ) {}

  get hasColdTier(): boolean {
    return this.cold !== null;
  }

  /** 冷存储所在的盘现在是否挂着（外接硬盘可能被拔掉）。 */
  get coldAvailable(): boolean {
    if (!this.cold) return false;
    const removable = this.cold as Partial<RemovableBackend>;
    return typeof removable.available === 'function' ? removable.available() : true;
  }

  private store(tier: string): StorageBackend {
    if (tier !== 'cold') return this.backend;
    if (!this.cold) throw new Error('blob is in cold storage but MEDIA_COLD_ROOT is not configured');
    return this.cold;
  }

  /** 原件被清理或重新下载回来（用于更新消息里的媒体状态）。 */
  onPresenceChanged: ((sha256: string, present: boolean) => void) | null = null;

  /**
   * 存入一份内容：写入内容寻址存储并登记 blobs（同样内容只存一份）。
   * 两阶段：先写临时文件算哈希，再在 blobs 行锁内放进存储——与原件清理互斥；
   * 之前被清理过的原件重新下载回来时，恢复占用统计并通知更新消息。
   */
  async storeBlob(
    source: Readable | AsyncIterable<Uint8Array>,
    meta: {
      kind?: string;
      mime?: string;
      width?: number;
      height?: number;
      durationMs?: number;
      maxBytes?: number;
      expectedSha256?: string;
    } = {},
  ): Promise<BlobRecord & { existed: boolean }> {
    const staged = await this.backend.stage(source, {
      ...(meta.maxBytes === undefined ? {} : { maxBytes: meta.maxBytes }),
      ...(meta.expectedSha256 ? { expectedSha256: meta.expectedSha256 } : {}),
    });
    let restored = false;
    try {
      // 类型以文件头为准（QQ 给的 Content-Type 经常不对）；识别不出来才用声明的具体类型。
      const sniffed = sniffMime(await readHead(staged.tmpPath));
      const mime = chooseMime(sniffed, meta.mime);
      const record = await this.db.transaction(async (tx) => {
        const inserted = await tx.execute(
          sql`insert into blobs (sha256, md5, md5_head, size, mime, kind, width, height, duration_ms, storage_key)
              values (${staged.sha256}, ${staged.md5}, ${staged.md5Head}, ${staged.size}, ${mime}, ${meta.kind ?? null},
                      ${meta.width ?? null}, ${meta.height ?? null}, ${meta.durationMs ?? null}, ${staged.key})
              on conflict (sha256) do nothing`,
        );
        const row = await one(
          tx,
          sql`select sha256, md5, md5_head, size, mime, kind, state, storage_key, tier from blobs where sha256 = ${staged.sha256} for update`,
        );
        let fileExisted: boolean;
        let tier: Tier = row.tier === 'cold' ? 'cold' : 'hot';
        if (row.state === 'present' && tier === 'cold' && this.coldAvailable) {
          // 原件已在冷存储：不在热存储里再放一份。
          await this.backend.discard(staged);
          fileExisted = true;
        } else {
          fileExisted = (await this.backend.commit(staged)).existed;
          if (row.state === 'present' && tier === 'cold') {
            // 冷存储的盘不在（外接硬盘拔了）、从 QQ 重新拿回来的：改放热存储。
            // 盘上那份成了孤儿，盘回来后由 TierManager.sweepColdOrphans 清掉。
            await tx.execute(
              sql`update blobs set storage_key = ${staged.key}, tier = 'hot', cold_since = null, access_count = 0 where sha256 = ${staged.sha256}`,
            );
            tier = 'hot';
          }
        }
        if (row.state === 'purged') {
          // 清理过的原件重新下载回来：放进热存储。
          await tx.execute(
            sql`update blobs set storage_key = ${staged.key}, tier = 'hot', cold_since = null, access_count = 0 where sha256 = ${staged.sha256}`,
          );
          tier = 'hot';
          restored = await setBlobPresence(tx, staged.sha256, true);
        }
        // 识别出的类型优先（同一内容的识别结果是确定的，顺带纠正以前存错的类型）。
        const finalMime = sniffed ?? (row.mime as string | null) ?? mime;
        if (finalMime !== row.mime || (!row.kind && meta.kind)) {
          await tx.execute(
            sql`update blobs set mime = ${finalMime}, kind = coalesce(kind, ${meta.kind ?? null})
                 where sha256 = ${staged.sha256}`,
          );
        }
        return {
          sha256: staged.sha256,
          md5: row.md5 as string,
          md5Head: row.md5_head as string,
          size: row.size as number,
          mime: finalMime,
          kind: ((row.kind as string | null) ?? meta.kind) || null,
          state: 'present' as const,
          storageKey: tier === 'cold' ? (row.storage_key as string) : staged.key,
          tier,
          existed: fileExisted || (inserted.rowCount ?? 0) === 0,
        };
      });
      if (restored) this.onPresenceChanged?.(record.sha256, true);
      return record;
    } catch (error) {
      await this.backend.discard(staged);
      throw error;
    }
  }

  /**
   * 删除原件（缩略图、预览图是独立的内容，不受影响）。发件箱里还要发送的内容不删。
   * 在 blobs 行锁内先改状态与占用统计、再删文件，与 storeBlob 互斥。返回是否真的删了。
   */
  async purgeOriginal(sha256: string): Promise<{ purged: boolean; size: number }> {
    const result = await this.db.transaction(async (tx) => {
      const row = await maybeOne<{ state: string; storage_key: string; size: number; tier: string }>(
        tx,
        sql`select state, storage_key, size, tier from blobs where sha256 = ${sha256} for update`,
      );
      if (!row || row.state !== 'present') return { purged: false, size: 0 };
      const sending = await maybeOne(
        tx,
        sql`select 1 as x from outbox
             where state in ('pending', 'sending') and content->'segments' @> ${JSON.stringify([{ sha256 }])}::jsonb
             limit 1`,
      );
      if (sending) return { purged: false, size: 0 };
      await setBlobPresence(tx, sha256, false);
      await this.store(row.tier).delete(row.storage_key);
      await tx.execute(sql`update blobs set tier = 'hot', cold_since = null where sha256 = ${sha256}`);
      return { purged: true, size: row.size };
    });
    if (result.purged) this.onPresenceChanged?.(sha256, false);
    return result;
  }

  async getBlob(sha256: string): Promise<BlobRecord | null> {
    const row = await maybeOne(
      this.db,
      sql`select sha256, md5, md5_head, size, mime, kind, state, storage_key, tier from blobs where sha256 = ${sha256}`,
    );
    if (!row) return null;
    return {
      sha256: row.sha256 as string,
      md5: row.md5 as string,
      md5Head: row.md5_head as string,
      size: row.size as number,
      mime: (row.mime as string | null) ?? null,
      kind: (row.kind as string | null) ?? null,
      state: row.state as 'present' | 'purged',
      storageKey: row.storage_key as string,
      tier: row.tier === 'cold' ? 'cold' : 'hot',
    };
  }

  async openBlob(blob: BlobRecord, range?: { start: number; end?: number }) {
    return this.store(blob.tier).open(blob.storageKey, range);
  }

  localPath(blob: BlobRecord): string | null {
    const store = this.store(blob.tier);
    return store.localPath?.(blob.storageKey) ?? null;
  }

  /**
   * 把原件移到另一层（热 ⇄ 冷）。在 blobs 行锁内先写进目标层（按 sha256 校验）、改记录，提交后再删源文件：
   * 中途出错最多留下一份多余的文件，不会丢内容。返回移动的字节数（没移动返回 0）。
   */
  async moveTier(sha256: string, target: Tier): Promise<number> {
    if (target === 'cold' && !this.cold) return 0;
    let source: { store: StorageBackend; key: string } | null = null;
    const moved = await this.db.transaction(async (tx) => {
      const row = await maybeOne<{ state: string; storage_key: string; size: number; tier: string }>(
        tx,
        sql`select state, storage_key, size, tier from blobs where sha256 = ${sha256} for update`,
      );
      if (!row || row.state !== 'present' || row.tier === target) return 0;
      if (!this.coldAvailable) return 0; // 冷存储的盘不在：哪个方向都搬不了
      const from = this.store(row.tier);
      const to = this.store(target);
      const staged = await to.stage(await from.open(row.storage_key), { expectedSha256: sha256 });
      try {
        await to.commit(staged);
      } catch (error) {
        await to.discard(staged);
        throw error;
      }
      await tx.execute(
        sql`update blobs set tier = ${target}, storage_key = ${staged.key}, access_count = 0,
                             cold_since = ${target === 'cold' ? sql`now()` : sql`null`}
             where sha256 = ${sha256}`,
      );
      source = { store: from, key: row.storage_key };
      return row.size;
    });
    const src = source as { store: StorageBackend; key: string } | null;
    if (src) await src.store.delete(src.key).catch(() => undefined);
    return moved;
  }

  /**
   * 清理冷存储里的孤儿文件：盘不在期间从 QQ 取回到热存储的内容、已清理的原件，盘上那份就没人用了。
   * 只删超过 1 小时没动过的文件（避免和正在进行的下沉撞上）。返回删除的文件数。
   */
  async sweepColdOrphans(minAgeMs = 3600_000): Promise<number> {
    const cold = this.cold as Partial<RemovableBackend> | null;
    if (!cold || !this.coldAvailable || typeof cold.keys !== 'function') return 0;
    let removed = 0;
    let batch: string[] = [];
    const flush = async () => {
      if (batch.length === 0) return;
      const keep = new Set(
        (
          await rows<{ sha256: string }>(
            this.db,
            sql`select sha256 from blobs where tier = 'cold' and state = 'present' and sha256 in (${sql.join(
              batch.map((b) => sql`${b}`),
              sql`, `,
            )})`,
          )
        ).map((r) => r.sha256),
      );
      for (const sha256 of batch) {
        if (keep.has(sha256)) continue;
        const key = keyForSha256(sha256);
        const file = cold.localPath?.(key);
        const stat = file ? await fs.stat(file).catch(() => null) : null;
        if (!stat || Date.now() - stat.mtimeMs < minAgeMs) continue;
        await this.cold!.delete(key);
        removed += 1;
      }
      batch = [];
    };
    for await (const sha256 of cold.keys()) {
      batch.push(sha256);
      if (batch.length >= 500) await flush();
    }
    await flush();
    return removed;
  }

  /**
   * 记一次原件访问（10 分钟内重复访问只算一次）。返回访问后的层级与计数，供调用方决定要不要提回热存储。
   */
  async touch(sha256: string): Promise<{ tier: Tier; accessCount: number } | null> {
    const row = await maybeOne<{ tier: string; access_count: number }>(
      this.db,
      sql`update blobs set last_access_at = now(), access_count = access_count + 1
           where sha256 = ${sha256} and (last_access_at is null or last_access_at < now() - interval '10 minutes')
           returning tier, access_count`,
    );
    return row ? { tier: row.tier === 'cold' ? 'cold' : 'hot', accessCount: row.access_count } : null;
  }

  /** 秒传判定：客户端算好 sha256，服务端已有就不必上传。 */
  async hasContent(sha256: string, size: number): Promise<boolean> {
    const row = await maybeOne(
      this.db,
      sql`select 1 as x from blobs where sha256 = ${sha256} and size = ${size} and state = 'present'`,
    );
    return Boolean(row);
  }

  /** 这份内容出现在哪些地方（只返回该账号能看到的会话）。 */
  async listUsages(accountId: number, sha256: string, limit = 500): Promise<MediaUsage[]> {
    const list = await rows(
      this.db,
      sql`select r.chat_id, c.scene, c.peer_id, r.message_seq, r.forward_bundle_id, r.node_path, r.sender_uin, r.time, r.role, r.kind
            from media_refs r join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
           where r.sha256 = ${sha256} and q.account_id = ${accountId}
           order by r.time desc
           limit ${limit}`,
    );
    return list.map((r) => ({
      chatId: r.chat_id as number,
      scene: r.scene as Scene,
      peerId: r.peer_id as number,
      messageSeq: (r.message_seq as number | null) ?? null,
      forwardBundleId: (r.forward_bundle_id as string | null) ?? null,
      nodePath: (r.node_path as number[] | null) ?? null,
      senderUin: (r.sender_uin as number | null) ?? null,
      time: toDate(r.time)!,
      role: r.role as string,
      kind: r.kind as string,
    }));
  }

  async storageOverview(accountId: number, limit = 100): Promise<StorageOverview> {
    const totals = await one<{ physical: number; blob_count: number; logical: number; hot: number; cold: number }>(
      this.db,
      sql`with mine as (
            select c.id from chats c join qq_accounts q on q.id = c.qq_account_id where q.account_id = ${accountId}
          ), used as (
            select distinct u.sha256 from chat_blob_usage u where u.chat_id in (select id from mine)
          ), t as (
            -- 一次扫完（原来对同一批内容扫三遍）：2026-10-25 实测 94–158 ms → 51–56 ms，结果相同。
            select coalesce(sum(b.size) filter (where b.state = 'present'), 0)::bigint as physical,
                   coalesce(sum(b.size) filter (where b.state = 'present' and b.tier = 'hot'), 0)::bigint as hot,
                   coalesce(sum(b.size) filter (where b.state = 'present' and b.tier = 'cold'), 0)::bigint as cold,
                   count(*)::int as blob_count
              from used left join blobs b on b.sha256 = used.sha256
          )
          select t.*, coalesce((select sum(s.logical_bytes) from chat_storage s where s.chat_id in (select id from mine)), 0)::bigint as logical
            from t`,
    );
    const chats = await rows(
      this.db,
      sql`select s.chat_id, c.scene, c.peer_id, s.logical_bytes, s.exclusive_bytes, s.blob_count,
                 coalesce(t.hot, 0)::bigint as hot_bytes, coalesce(t.cold, 0)::bigint as cold_bytes
            from chat_storage s join chats c on c.id = s.chat_id join qq_accounts q on q.id = c.qq_account_id
            left join lateral (
              select sum(b.size) filter (where b.tier = 'hot') as hot, sum(b.size) filter (where b.tier = 'cold') as cold
                from chat_blob_usage u join blobs b on b.sha256 = u.sha256
               where u.chat_id = s.chat_id and b.state = 'present'
            ) t on true
           where q.account_id = ${accountId} and s.blob_count > 0
           order by s.logical_bytes desc, s.chat_id
           limit ${limit}`,
    );
    return {
      physicalBytes: totals.physical,
      logicalBytes: totals.logical,
      dedupSavedBytes: Math.max(0, totals.logical - totals.physical),
      blobCount: totals.blob_count,
      hotBytes: Number(totals.hot),
      coldBytes: Number(totals.cold),
      chats: chats.map((r) => ({
        chatId: r.chat_id as number,
        scene: r.scene as Scene,
        peerId: r.peer_id as number,
        logicalBytes: r.logical_bytes as number,
        exclusiveBytes: r.exclusive_bytes as number,
        blobCount: r.blob_count as number,
        hotBytes: Number(r.hot_bytes),
        coldBytes: Number(r.cold_bytes),
      })),
    };
  }

  /**
   * 服务端上所有内容按用途分类（去重后，每份内容只算一次）。优先级：消息里的媒体（按第一次出现时的角色和类型）
   * → 群文件 → 头像 → 服务端生成的派生内容（缩略图、预览图、语音转码）→ 其他。
   */
  async storageCategories(): Promise<StorageCategoryStat[]> {
    const list = await rows<{ category: string; bytes: number; count: number }>(
      this.db,
      sql`with first_ref as (
            select distinct on (sha256) sha256, role, kind from media_refs where sha256 is not null order by sha256, id
          ), cls as (
            select b.size,
                   case
                     when r.role = 'qq_thumb' then 'qq_thumb'
                     when r.role = 'sticker' or r.kind = 'sticker' or (r.sha256 is null and b.kind = 'sticker') then 'sticker'
                     when r.kind = 'image' then 'image'
                     when r.kind = 'video' then 'video'
                     when r.kind in ('record', 'audio') then 'record'
                     when r.kind = 'file' then 'file'
                     when g.sha256 is not null then 'group_file'
                     when a.sha256 is not null then 'avatar'
                     when v.sha256 is not null then 'derived'
                     else 'other'
                   end as category
              from blobs b
              left join first_ref r on r.sha256 = b.sha256
              left join (select distinct sha256 from group_file_blobs) g on g.sha256 = b.sha256
              left join (select distinct avatar_sha256 as sha256 from peers where avatar_sha256 is not null) a on a.sha256 = b.sha256
              left join (select distinct variant_sha256 as sha256 from blob_variants) v on v.sha256 = b.sha256
             where b.state = 'present'
          )
          select category, coalesce(sum(size), 0)::bigint as bytes, count(*)::int as count from cls group by category order by bytes desc`,
    );
    return list.map((r) => ({ category: r.category, bytes: Number(r.bytes), count: r.count }));
  }

  /** 热存储 / 冷存储所在磁盘的容量（冷存储的盘没挂上时 available = false）。 */
  async volumes(): Promise<StorageVolumeStat[]> {
    const stat = async (tier: 'hot' | 'cold', backend: StorageBackend | null): Promise<StorageVolumeStat | null> => {
      if (!backend) return null;
      const b = backend as StorageBackend & { root?: string; available?: () => boolean };
      const root = b.root;
      const available = b.available ? b.available() : true;
      if (!root || !available) return { tier, available: false, totalBytes: 0, freeBytes: 0 };
      try {
        const s = await fs.statfs(root);
        return { tier, available: true, totalBytes: s.blocks * s.bsize, freeBytes: s.bavail * s.bsize };
      } catch {
        return { tier, available: false, totalBytes: 0, freeBytes: 0 };
      }
    };
    return (await Promise.all([stat('hot', this.backend), stat('cold', this.cold)])).filter((v): v is StorageVolumeStat => v !== null);
  }

  /** 单个会话的占用明细：按类型拆分（逻辑 / 独占 / 冷热 / 已清理），以及最大的内容。 */
  async chatStorage(accountId: number, chatId: number, topLimit = 20): Promise<ChatStorageDetail> {
    const chat = await maybeOne<{ scene: Scene; peer_id: number; logical_bytes: number | null; exclusive_bytes: number | null; blob_count: number | null }>(
      this.db,
      sql`select c.scene, c.peer_id, s.logical_bytes, s.exclusive_bytes, s.blob_count
            from chats c join qq_accounts q on q.id = c.qq_account_id left join chat_storage s on s.chat_id = c.id
           where c.id = ${chatId} and q.account_id = ${accountId}`,
    );
    if (!chat) throw new NotFoundError(`chat ${chatId} not found`);
    // 每个内容在本会话里按第一次出现时的类型归类。
    const perBlob = sql`
      select distinct on (r.sha256) r.sha256, r.kind, r.message_seq, b.size, b.state, b.tier, b.ref_chats, b.last_access_at
        from media_refs r join blobs b on b.sha256 = r.sha256
       where r.chat_id = ${chatId}
       order by r.sha256, r.id`;
    const kinds = await rows<{ kind: string; count: number; logical: number; exclusive: number; hot: number; cold: number; purged: number }>(
      this.db,
      sql`with per_blob as (${perBlob})
          select kind, count(*)::int as count,
                 coalesce(sum(size) filter (where state = 'present'), 0)::bigint as logical,
                 coalesce(sum(size) filter (where state = 'present' and ref_chats = 1), 0)::bigint as exclusive,
                 coalesce(sum(size) filter (where state = 'present' and tier = 'hot'), 0)::bigint as hot,
                 coalesce(sum(size) filter (where state = 'present' and tier = 'cold'), 0)::bigint as cold,
                 count(*) filter (where state = 'purged')::int as purged
            from per_blob group by kind order by logical desc`,
    );
    const largest = await rows<{ sha256: string; size: number; kind: string; state: string; tier: string; ref_chats: number; last_access_at: Date | string | null; first_seq: number | null }>(
      this.db,
      sql`with per_blob as (${perBlob})
          select p.sha256, p.size, p.kind, p.state, p.tier, p.ref_chats, p.last_access_at,
                 (select min(r.message_seq) from media_refs r where r.chat_id = ${chatId} and r.sha256 = p.sha256) as first_seq
            from per_blob p order by p.size desc limit ${topLimit}`,
    );
    const hot = kinds.reduce((n, k) => n + Number(k.hot), 0);
    const cold = kinds.reduce((n, k) => n + Number(k.cold), 0);
    return {
      summary: {
        chatId,
        scene: chat.scene,
        peerId: Number(chat.peer_id),
        logicalBytes: Number(chat.logical_bytes ?? 0),
        exclusiveBytes: Number(chat.exclusive_bytes ?? 0),
        blobCount: Number(chat.blob_count ?? 0),
        hotBytes: hot,
        coldBytes: cold,
      },
      kinds: kinds.map((k) => ({
        kind: k.kind,
        count: k.count,
        logicalBytes: Number(k.logical),
        exclusiveBytes: Number(k.exclusive),
        hotBytes: Number(k.hot),
        coldBytes: Number(k.cold),
        purgedCount: k.purged,
      })),
      largest: largest.map((l) => ({
        sha256: l.sha256,
        size: Number(l.size),
        kind: l.kind,
        tier: l.state === 'purged' ? 'purged' : l.tier === 'cold' ? 'cold' : 'hot',
        shared: Number(l.ref_chats) > 1,
        lastAccessAt: l.last_access_at ? new Date(l.last_access_at) : null,
        firstSeq: l.first_seq === null ? null : Number(l.first_seq),
      })),
    };
  }

  /**
   * 预估"清理某会话里符合条件的媒体原件"能释放多少空间。
   * 只有所有引用方（包括其他会话、其他保留策略）都不再需要原件的内容才会被删除。
   */
  async planCleanup(accountId: number, chatId: number, criteria: CleanupCriteria, nowSec = Math.floor(Date.now() / 1000)): Promise<CleanupPlan> {
    const chat = await maybeOne(
      this.db,
      sql`select c.id from chats c join qq_accounts q on q.id = c.qq_account_id where c.id = ${chatId} and q.account_id = ${accountId}`,
    );
    if (!chat) throw new NotFoundError(`chat ${chatId} not found`);

    const cutoff = criteria.olderThanDays === undefined ? null : new Date((nowSec - criteria.olderThanDays * 86_400) * 1000).toISOString();
    const kinds = criteria.kinds && criteria.kinds.length > 0 ? criteria.kinds : null;
    const candidates = await rows<{ id: number; sha256: string }>(
      this.db,
      sql`select r.id, r.sha256 from media_refs r join blobs b on b.sha256 = r.sha256
           where r.chat_id = ${chatId} and b.state = 'present'
             ${kinds ? sql`and r.kind in (${sql.join(kinds.map((k) => sql`${k}`), sql`, `)})` : sql``}
             ${cutoff ? sql`and r.time < ${cutoff}::timestamptz` : sql``}`,
    );
    const candidateRefIds = new Set(candidates.map((c) => c.id));
    const blobShas = [...new Set(candidates.map((c) => c.sha256))];
    if (blobShas.length === 0) {
      return { refCount: 0, blobCount: 0, purgeableBlobCount: 0, freedBytes: 0, keptSharedBlobCount: 0, candidateRefIds: [] };
    }

    const shaList = sql.join(blobShas.map((s) => sql`${s}`), sql`, `);
    const allRefs = await rows<{ id: number; sha256: string; chat_id: number; scene: Scene; account_id: number; t: number; keep_original: boolean | null }>(
      this.db,
      sql`select r.id, r.sha256, r.chat_id, c.scene, q.account_id, extract(epoch from r.time)::bigint as t, r.keep_original
            from media_refs r join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
           where r.sha256 in (${shaList})`,
    );
    const policiesByAccount = await retentionPolicies(this.db, [...new Set(allRefs.map((r) => r.account_id))]);

    const sizes = new Map(
      (await rows<{ sha256: string; size: number }>(this.db, sql`select sha256, size from blobs where sha256 in (${shaList})`)).map(
        (r) => [r.sha256, r.size],
      ),
    );
    let purgeable = 0;
    let freed = 0;
    for (const sha of blobShas) {
      const refs: RefRetention[] = allRefs
        .filter((r) => r.sha256 === sha)
        .map((r) => ({
          time: r.t,
          override: candidateRefIds.has(r.id) ? false : r.keep_original,
          rule: resolveRule(policiesByAccount.get(r.account_id) ?? [], { chatId: r.chat_id, scene: r.scene }),
        }));
      if (originalPurgeable(refs, nowSec)) {
        purgeable += 1;
        freed += sizes.get(sha) ?? 0;
      }
    }
    return {
      refCount: candidates.length,
      blobCount: blobShas.length,
      purgeableBlobCount: purgeable,
      freedBytes: freed,
      keptSharedBlobCount: blobShas.length - purgeable,
      candidateRefIds: [...candidateRefIds],
    };
  }
}
