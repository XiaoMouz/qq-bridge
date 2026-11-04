// 存储页的浏览：某几类内容在各会话的占用（MediaService.ListStorageChats）、某个会话里的具体内容（ListStorageItems）。
// 类别和 MediaService.storageCategories 一致：image / qq_thumb / sticker / video / record / file / group_file，
// 另有 message = 消息本身（各会话条数 × 全表平均每行大小的估算，缓存 1 小时）。
// 这些查询都经 SharedResults：同样的请求同时只跑一份，每条带 STATS_TIMEOUT_MS 超时。
import { sql, type SQL } from 'drizzle-orm';
import { rows, type Db, type Tx } from '../db/client.ts';
import { SharedResults, STATS_TIMEOUT_MS, withStatementTimeout } from '../db/shared.ts';
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

const MESSAGE_TTL_MS = 60 * 60_000;
/** 表大小：pg_total_relation_size 要逐个文件 stat，负载高时 1 秒多。 */
const TABLE_SIZE_TTL_MS = 60_000;

export class StorageBrowser {
  private shared = new SharedResults();

  constructor(private readonly db: Db) {}

  private query<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return withStatementTimeout(this.db, STATS_TIMEOUT_MS, fn);
  }

  /** 消息本身占的空间（整张表，含索引）。 */
  messageBytes(): Promise<number> {
    return this.shared.run(
      'messageBytes',
      async () => {
        const [r] = await rows<{ n: number }>(this.db, sql`select pg_total_relation_size('messages')::bigint as n`);
        return Number(r?.n ?? 0);
      },
      { ttlMs: TABLE_SIZE_TTL_MS, stale: true },
    );
  }

  /** 消息条数：用表统计信息估算（不扫全表）。 */
  async messageCount(): Promise<number> {
    const [r] = await rows<{ n: number }>(this.db, sql`select greatest(reltuples, 0)::bigint as n from pg_class where oid = 'messages'::regclass`);
    return Number(r?.n ?? 0);
  }

  chats(accountId: number, categories: string[], limit = 100): Promise<StorageChatRow[]> {
    const cats = [...new Set(categories.filter(Boolean))].sort();
    return this.shared.run(`chats:${accountId}:${cats.join(',')}:${limit}`, () => this.loadChats(accountId, cats, limit));
  }

  private async loadChats(accountId: number, cats: string[], limit: number): Promise<StorageChatRow[]> {
    const out: StorageChatRow[] = [];
    if (cats.includes('message')) out.push(...(await this.messageChats(accountId)));
    const media = cats.filter((c) => (MEDIA_CATEGORIES as readonly string[]).includes(c));
    if (media.length > 0) {
      const list = await this.query((tx) => rows<{ chat_id: number; scene: Scene; peer_id: number; bytes: number; count: number }>(
        tx,
        sql`with refs as (
              select distinct r.chat_id, r.sha256 from media_refs r
                join chats c on c.id = r.chat_id join qq_accounts q on q.id = c.qq_account_id
               where q.account_id = ${accountId} and r.sha256 is not null and ${CATEGORY} in ${inList(media)}
            )
            select refs.chat_id, c.scene, c.peer_id, sum(b.size)::bigint as bytes, count(*)::int as count
              from refs join blobs b on b.sha256 = refs.sha256 and b.state = 'present'
              join chats c on c.id = refs.chat_id
             group by 1, 2, 3 order by bytes desc limit ${limit}`,
      ));
      out.push(...list.map((r) => ({ chatId: r.chat_id, scene: r.scene, peerId: r.peer_id, bytes: Number(r.bytes), count: r.count })));
    }
    if (cats.includes('group_file')) {
      const list = await this.query((tx) => rows<{ chat_id: number; scene: Scene; peer_id: number; bytes: number; count: number }>(
        tx,
        sql`select c.id as chat_id, c.scene, c.peer_id, sum(b.size)::bigint as bytes, count(*)::int as count
              from group_file_blobs g join blobs b on b.sha256 = g.sha256 and b.state = 'present'
              join qq_accounts q on q.id = g.qq_account_id
              join chats c on c.qq_account_id = g.qq_account_id and c.scene = 'group' and c.peer_id = g.group_id
             where q.account_id = ${accountId}
             group by 1, 2, 3 order by bytes desc limit ${limit}`,
      ));
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

  items(accountId: number, chatId: number | null, categories: string[], offset: number, limit: number): Promise<StorageItemRow[]> {
    const cats = [...new Set(categories.filter(Boolean))].sort();
    return this.shared.run(`items:${accountId}:${chatId ?? 0}:${cats.join(',')}:${offset}:${limit}`, () =>
      this.loadItems(accountId, chatId, cats, offset, limit),
    );
  }

  private async loadItems(accountId: number, chatId: number | null, categories: string[], offset: number, limit: number): Promise<StorageItemRow[]> {
    const media = categories.filter((c) => (MEDIA_CATEGORIES as readonly string[]).includes(c));
    const parts: SQL[] = [];
    if (media.length > 0) {
      parts.push(sql`
        select distinct on (r.sha256) r.sha256, b.size, ${CATEGORY} as category, b.state, b.tier, b.ref_chats,
               r.chat_id, coalesce(r.message_seq, fb.message_seq) as seq, r.time, b.mime, r.name,
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
          -- 合并转发里的媒体没有自己的消息：出处是外层那条合并转发消息（forward_bundle_id 存的是 forward_bundles.id 的文本）。
          left join forward_bundles fb on r.forward_bundle_id is not null and fb.id = r.forward_bundle_id::bigint
         where q.account_id = ${accountId} and r.sha256 is not null and ${CATEGORY} in ${inList(media)}
           ${chatId ? sql`and r.chat_id = ${chatId}` : sql``}
         -- 每份内容取一条出处给客户端「在聊天中查看」：直接出现在 QQ 消息里的优先，其次合并转发的外层消息，
         -- 再次备份导入的替代 seq（负数），同一档里取最早的。
         order by r.sha256,
                  case when r.message_seq > 0 then 0 when fb.message_seq is not null then 1 when r.message_seq < 0 then 2 else 3 end,
                  r.time`);
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
    const list = await this.query((tx) =>
      rows<Record<string, unknown>>(
        tx,
        sql`select * from (${union}) x order by (state = 'present') desc, size desc, sha256 limit ${limit} offset ${offset}`,
      ),
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

  /**
   * 各会话消息本身占的空间：条数 × 全表平均每行（含索引、TOAST）。原来按 sum(pg_column_size(m.*)) 逐行算，
   * m.* 要把 TOAST 里的大字段读出来解开，等于把整张表读一遍：2026-10-24 约 2.4 秒，备份导入后（1100 万行、15 GB）
   * 2026-11-04 实测 289 秒；改成按 (chat_id, seq) 索引数条数后约 2.2 秒。图片、卡片多的会话会被略微低估，排序基本不变。
   * 有结果就先给（过期了后台重算，同时只算一次），只有从没算过时才等；服务端启动后先在后台算好（warm）。
   */
  private messageChats(accountId: number): Promise<StorageChatRow[]> {
    return this.shared.run(`messages:${accountId}`, () => this.loadMessageChats(accountId), { ttlMs: MESSAGE_TTL_MS, stale: true });
  }

  /** 后台先把各账号的消息占用算好（启动后调用一次）。 */
  async warm(): Promise<void> {
    for (const a of await rows<{ id: number }>(this.db, sql`select id from accounts`)) await this.messageChats(a.id);
  }

  private async loadMessageChats(accountId: number): Promise<StorageChatRow[]> {
    const list = await this.query((tx) =>
      rows<{ chat_id: number; scene: Scene; peer_id: number; bytes: number; count: number }>(
        tx,
        sql`with n as (
              select chat_id, count(*) as count from messages group by chat_id
            ), per as (
              select pg_total_relation_size('messages')::float8 / greatest(reltuples, 1) as b from pg_class where oid = 'messages'::regclass
            )
            select n.chat_id, c.scene, c.peer_id, (n.count * per.b)::bigint as bytes, n.count::int as count
              from n cross join per join chats c on c.id = n.chat_id join qq_accounts q on q.id = c.qq_account_id
             where q.account_id = ${accountId}
             order by n.count desc limit 200`,
      ),
    );
    return list.map((r) => ({ chatId: r.chat_id, scene: r.scene, peerId: r.peer_id, bytes: Number(r.bytes), count: r.count }));
  }
}

function inList(values: readonly string[]): SQL {
  return sql`(${sql.join(values.map((v) => sql`${v}`), sql`, `)})`;
}
