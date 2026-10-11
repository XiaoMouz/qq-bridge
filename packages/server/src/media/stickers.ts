// 我收藏的表情：列表一次向 QQ 拿全（插件 x.fav_emojis），缓存 10 分钟；
// 图片按需准备：先按 md5 找已有内容（收到过同一张表情就不用再下），没有再从 QQ 的表情图床下载，存成 blob 并生成缩略图。
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { UpstreamHub } from '../upstream/hub.ts';
import type { MediaProcessor } from './processing.ts';
import type { MediaService } from './service.ts';

export interface StickerItem {
  md5: string;
  url: string;
  desc: string;
  market: boolean;
  sha256?: string;
  thumbSha256?: string;
}

const LIST_TTL_MS = 10 * 60_000;

export class StickerService {
  private cache = new Map<number, { at: number; items: StickerItem[] }>();

  constructor(
    private readonly db: Db,
    private readonly media: Pick<MediaService, 'storeBlob'>,
    private readonly processor: Pick<MediaProcessor, 'process'> | null,
    private readonly upstream: () => Pick<UpstreamHub, 'call' | 'isConnected'> | null,
    private readonly logger?: Logger,
    private readonly download: (url: string) => Promise<Buffer | null> = defaultDownload,
  ) {}

  /** 插件（QQ 容器）下载服务端媒体用的签名链接；服务端启动时按配置设置，没有上游时为 null。 */
  pluginUrl: ((sha256: string, name: string) => string) | null = null;

  /** 加到"我的表情"：插件从签名链接下载后交给 QQ。成功后列表缓存作废，下次打开面板就有了。 */
  async add(accountId: number, sha256: string): Promise<void> {
    const qq = await this.qqAccount(accountId);
    const blob = await maybeOne<{ mime: string | null; kind: string }>(
      this.db,
      sql`select mime, kind from blobs where sha256 = ${sha256} and state = 'present'`,
    );
    if (!blob || !['image', 'sticker'].includes(blob.kind)) throw new Error('not an image on this server');
    const hub = this.upstream();
    if (!hub?.isConnected(qq) || !this.pluginUrl) throw new Error('QQ is offline');
    const ext = blob.mime === 'image/gif' ? 'gif' : blob.mime === 'image/jpeg' ? 'jpg' : blob.mime === 'image/webp' ? 'webp' : 'png';
    const name = `sticker.${ext}`;
    await hub.call(qq, 'x.add_fav_emoji', { url: this.pluginUrl(sha256, name), name }, 90_000);
    this.cache.delete(qq);
  }

  async list(accountId: number, refresh: boolean): Promise<StickerItem[]> {
    const qq = await this.qqAccount(accountId);
    const cached = this.cache.get(qq);
    let items = cached?.items;
    if (!items || refresh || Date.now() - (cached?.at ?? 0) > LIST_TTL_MS) {
      const hub = this.upstream();
      if (hub?.isConnected(qq)) {
        const res = await hub.call<{ emojis: { md5: string; url: string; isMarkFace: boolean; desc: string }[] }>(qq, 'x.fav_emojis', {}, 30_000);
        items = (res?.emojis ?? []).filter((e) => /^[0-9a-f]{32}$/.test(e.md5)).map((e) => ({ md5: e.md5, url: e.url, desc: e.desc, market: e.isMarkFace }));
        this.cache.set(qq, { at: Date.now(), items });
      } else if (!items) {
        throw new Error('QQ is offline');
      }
    }
    return this.withKnownBlobs(items ?? []);
  }

  /** 准备一批表情的图片，返回准备好的。 */
  async prepare(accountId: number, md5s: string[]): Promise<StickerItem[]> {
    const items = await this.list(accountId, false);
    const byMd5 = new Map(items.map((i) => [i.md5, i]));
    const out: StickerItem[] = [];
    for (const md5 of md5s.slice(0, 60)) {
      const item = byMd5.get(md5);
      if (!item) continue;
      if (item.sha256) {
        out.push(item);
        continue;
      }
      try {
        const data = await this.download(item.url);
        if (!data) continue;
        const blob = await this.media.storeBlob(Readable.from([data]), { kind: 'sticker', maxBytes: 10 * 1024 * 1024 });
        const derived = await this.processor?.process(blob.sha256, 'sticker');
        out.push({ ...item, sha256: blob.sha256, ...(derived?.thumbSha256 ? { thumbSha256: derived.thumbSha256 } : {}) });
      } catch (error) {
        this.logger?.debug({ err: error, md5 }, 'sticker download failed');
      }
    }
    return out;
  }

  /** 本账号收藏表情已准备好的内容（签发下载链接时放行）。 */
  async ownedSha256(accountId: number): Promise<Set<string>> {
    const qq = await this.qqAccount(accountId).catch(() => null);
    const items = qq === null ? [] : (this.cache.get(qq)?.items ?? []);
    const known = await this.withKnownBlobs(items);
    return new Set(known.flatMap((i) => [i.sha256, i.thumbSha256].filter((x): x is string => Boolean(x))));
  }

  /** 按 md5 找已经存过的内容（收到过的表情、之前准备过的）。 */
  private async withKnownBlobs(items: StickerItem[]): Promise<StickerItem[]> {
    if (items.length === 0) return items;
    const known = new Map(
      (
        await rows<{ md5: string; sha256: string; thumb: string | null }>(
          this.db,
          sql`select b.md5, b.sha256, v.variant_sha256 as thumb from blobs b
                left join blob_variants v on v.sha256 = b.sha256 and v.variant = 'thumb'
               where b.state = 'present' and b.md5 in (${sql.join(
                 items.map((i) => sql`${i.md5}`),
                 sql`, `,
               )})`,
        )
      ).map((r) => [r.md5, r]),
    );
    return items.map((i) => {
      const k = known.get(i.md5);
      return k ? { ...i, sha256: k.sha256, ...(k.thumb ? { thumbSha256: k.thumb } : {}) } : i;
    });
  }

  private async qqAccount(accountId: number): Promise<number> {
    const row = await maybeOne<{ id: number }>(this.db, sql`select id from qq_accounts where account_id = ${accountId} order by id limit 1`);
    if (!row) throw new Error('no QQ account is linked');
    return Number(row.id);
  }
}

async function defaultDownload(url: string): Promise<Buffer | null> {
  if (!/^https:\/\/[a-z0-9.-]+\.(qpic\.cn|qq\.com)\//.test(url)) return null; // 只从 QQ 的图床下载
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) return null;
  return Buffer.from(await res.arrayBuffer());
}
