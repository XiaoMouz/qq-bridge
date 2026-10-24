// 存储页的浏览：某几类内容在各会话的占用（MediaService.ListStorageChats）、某个会话里的具体内容（ListStorageItems）。
// 类别和 MediaService.storageCategories 一致：image / qq_thumb / sticker / video / record / file / group_file，
// 另有 message = 消息本身（按行大小算，全表扫描较慢，结果缓存 5 分钟）。
import { sql, type SQL } from 'drizzle-orm';
import { rows, type Db } from '../db/client.ts';
import type { Scene } from '@qqbridge/domain';

export const MEDIA_CATEGORIES = ['image', 'qq_thumb', 'sticker', 'video', 'record', 'file'] as const;

/** 一条媒体引用属于哪一类（与 storageCategories 的判断一致）。 */
const CATEGORY = sql.raw(`case
  when r.role = 'qq_thumb' then 'qq_thumb'
  when r.role = 'sticker' or r.kind = 'sticker' then 'sticker'
  when r.kind = 'image' then 'image'
  when r.kind = 'video' then 'video'
  when r.kind in ('record', 'audio') then 'record'
  when r.kind = 'file' then 'file'
  else 'other' end`);

export interface StorageChatRow {
  chatId: number;
  scene: Scene;
  peerId: number;
  bytes: number;
  count: number;
}

export interface StorageItemRow {
  sha256: string;
  size: number;
  category: string;
  state: string;
  tier: string;
  refChats: number;
  chatId: number;
  seq: number;
  time: Date | null;
  mime: string | null;
  name: string | null;
  thumbSha256: string | null;
}

const MESSAGE_TTL_MS = 5 * 60_000;

export class StorageBrowser {
  private messageCache = new Map<number, { at: number; rows: StorageChatRow[] }>();
  private messageRefresh = new Map<number, Promise<StorageChatRow[]>>();

  constructor(private readonly db: Db) {}

  /** 消息本身占的空间（整张表，含索引）。 */
  async messageBytes(): Promise<number> {
    const [r] = await rows<{ n: number }>(this.db, sql`select pg_total_relation_size('messages')::bigint as n`);
    return Number(r?.n ?? 0);
  }

  /** 消息条数：用表统计信息估算（不扫全表）。 */
  async messageCount(): Promise<number> {
    const [r] = await rows<{ n: number }>(this.db, sql`select greatest(reltuples, 0)::bigint as n from pg_class where oid = 'messages'::regclass`);
    return Number(r?.n ?? 0);
  }

  async chats(accountId: number, categories: string[], limit = 100): Promise<StorageChatRow[]> {
    const cats = categories.filter(Boolean);
    const out: StorageChatRow[] = [];
    if (cats.includes('message')) out.push(...(await this.messageChats(accountId)));
    const media = cats.filter((c) => (MEDIA_CATEGORIES as readonly string[]).includes(c));
    if (media.length > 0) {
      const list = await rows<{ chat_id: number; scene: Scene; peer_id: number; bytes: number; count: number }>(
        this.db,
        sql`with refs as (
              select distinct r.chat_id, r.sha256 from media_refs r
                join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
               where q.account_id = ${accountId} and r.sha256 is not null and ${CATEGORY} in ${inList(media)}
            )
            select refs.chat_id, c.scene, c.peer_id, sum(b.size)::bigint as bytes, count(*)::int as count
              from refs join blobs b on b.sha256 = refs.sha256 and b.state = 'present'
              join chats c on c.id = refs.chat_id
             group by 1, 2, 3 order by bytes desc limit ${limit}`,
      );
      out.push(...list.map((r) => ({ chatId: r.chat_id, scene: r.scene, peerId: r.peer_id, bytes: Number(r.bytes), count: r.count })));
    }
    if (cats.includes('group_file')) {
      const list = await rows<{ chat_id: number; scene: Scene; peer_id: number; bytes: number; count: number }>(
        this.db,
        sql`select c.id as chat_id, c.scene, c.peer_id, sum(b.size)::bigint as bytes, count(*)::int as count
              from group_file_blobs g join blobs b on b.sha256 = g.sha256 and b.state = 'present'
              join qq_accounts q on q.id = g.qq_account_id
              join chats c on c.qq_account_id = g.qq_account_id and c.scene = 'group' and c.peer_id = g.group_id
             where q.account_id = ${accountId}
             group by 1, 2, 3 order by bytes desc limit ${limit}`,
      );
      out.push(...list.map((r) => ({ chatId: r.chat_id, scene: r.scene, peerId: r.peer_id, bytes: Number(r.bytes), count: r.count })));
    }
    // 同一会话出现在几类里：合起来。
    const merged = new Map<number, StorageChatRow>();
    for (const r of out) {
      const m = merged.get(r.chatId);
      if (m) {
        m.bytes += r.bytes;
        m.count += r.count;
      } else merged.set(r.chatId, { ...r });
    }
    return [...merged.values()].sort((a, b) => b.bytes - a.bytes).slice(0, limit);
  }

  async items(accountId: number, chatId: number | null, categories: string[], offset: number, limit: number): Promise<StorageItemRow[]> {
    const media = categories.filter((c) => (MEDIA_CATEGORIES as readonly string[]).includes(c));
    const parts: SQL[] = [];
    if (media.length > 0) {
      parts.push(sql`
        select distinct on (r.sha256) r.sha256, b.size, ${CATEGORY} as category, b.state, b.tier, b.ref_chats,
               r.chat_id, r.message_seq as seq, r.time, b.mime, r.name,
               coalesce(
                 (select t.sha256 from media_refs t where t.chat_id = r.chat_id and t.message_seq = r.message_seq
                   and t.ordinal = r.ordinal and t.role = 'qq_thumb' and t.sha256 is not null limit 1),
                 (select v.variant_sha256 from blob_variants v where v.sha256 = r.sha256 and v.variant = 'thumb' limit 1),
                 (select s->'media'->>'thumbSha256' from messages m, jsonb_array_elements(m.segments) s
                   where m.chat_id = r.chat_id and m.seq = r.message_seq and (s->'media'->>'ord')::int = r.ordinal limit 1)
               ) as thumb_sha256
          from media_refs r
          join blobs b on b.sha256 = r.sha256
          join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
         where q.account_id = ${accountId} and r.sha256 is not null and ${CATEGORY} in ${inList(media)}
           ${chatId ? sql`and r.chat_id = ${chatId}` : sql``}
         order by r.sha256, r.time`);
    }
    if (categories.includes('group_file')) {
      parts.push(sql`
        select g.sha256, b.size, 'group_file' as category, b.state, b.tier, b.ref_chats,
               c.id as chat_id, 0::bigint as seq, g.created_at as time, b.mime, g.name, null::text as thumb_sha256
          from group_file_blobs g join blobs b on b.sha256 = g.sha256
          join qq_accounts q on q.id = g.qq_account_id
          join chats c on c.qq_account_id = g.qq_account_id and c.scene = 'group' and c.peer_id = g.group_id
         where q.account_id = ${accountId} ${chatId ? sql`and c.id = ${chatId}` : sql``}`);
    }
    if (parts.length === 0) return [];
    const union = sql.join(parts.map((p) => sql`(${p})`), sql` union all `);
    const list = await rows<Record<string, unknown>>(
      this.db,
      sql`select * from (${union}) x order by (state = 'present') desc, size desc, sha256 limit ${limit} offset ${offset}`,
    );
    return list.map((r) => ({
      sha256: r.sha256 as string,
      size: Number(r.size),
      category: r.category as string,
      state: r.state as string,
      tier: (r.tier as string | null) ?? 'hot',
      refChats: Number(r.ref_chats ?? 1),
      chatId: Number(r.chat_id),
      seq: Number(r.seq ?? 0),
      time: r.time ? new Date(r.time as string) : null,
      mime: (r.mime as string | null) ?? null,
      name: (r.name as string | null) ?? null,
      thumbSha256: (r.thumb_sha256 as string | null) || null,
    }));
  }

  /** 各会话消息本身的大小（按行算），缓存 5 分钟。 */
  /**
   * 各会话消息本身占的空间：要扫整张消息表（2026-10-24 实测内置盘约 2.4 秒，原来在 Ext1 上最长 12 秒）。
   * 有结果就先给（过期了在后台重算，同时只算一次），只有从没算过时才等；服务端启动后也会先在后台算好（warm）。
   */
  private async messageChats(accountId: number): Promise<StorageChatRow[]> {
    const cached = this.messageCache.get(accountId);
    if (cached) {
      if (Date.now() - cached.at >= MESSAGE_TTL_MS) void this.refreshMessageChats(accountId).catch(() => undefined);
      return cached.rows;
    }
    return this.refreshMessageChats(accountId);
  }

  /** 后台先把各账号的消息占用算好（启动后调用一次）。 */
  async warm(): Promise<void> {
    for (const a of await rows<{ id: number }>(this.db, sql`select id from accounts`)) await this.refreshMessageChats(a.id);
  }

  private refreshMessageChats(accountId: number): Promise<StorageChatRow[]> {
    const running = this.messageRefresh.get(accountId);
    if (running) return running;
    const task = (async () => {
      const list = await rows<{ chat_id: number; scene: Scene; peer_id: number; bytes: number; count: number }>(
        this.db,
        sql`select m.chat_id, c.scene, c.peer_id, sum(pg_column_size(m.*))::bigint as bytes, count(*)::int as count
              from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
             where q.account_id = ${accountId}
             group by 1, 2, 3 order by bytes desc limit 200`,
      );
      const out = list.map((r) => ({ chatId: r.chat_id, scene: r.scene, peerId: r.peer_id, bytes: Number(r.bytes), count: r.count }));
      this.messageCache.set(accountId, { at: Date.now(), rows: out });
      return out;
    })().finally(() => this.messageRefresh.delete(accountId));
    this.messageRefresh.set(accountId, task);
    return task;
  }
}

function inList(values: readonly string[]): SQL {
  return sql`(${sql.join(values.map((v) => sql`${v}`), sql`, `)})`;
}
