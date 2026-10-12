// 群公告、群精华、群文件（ContactService.ListGroupNotices / ListGroupEssence / ListGroupFiles / FetchGroupFile）。
// 列表在打开页面时当场向 QQ 拉，不缓存；群文件下载过一次就记住（group_file_blobs），之后直接按 sha256 取。
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import { addUsage } from '../media/accounting.ts';
import type { MediaService } from '../media/service.ts';
import { MESSAGE_COLUMNS, sqlList, toMessage, type MessageRow } from '../sync/rows.ts';
import type { UpstreamHub } from '../upstream/hub.ts';

export class GroupContentError extends Error {
  constructor(
    readonly code: 'not_found' | 'offline' | 'unavailable',
    message: string,
  ) {
    super(message);
  }
}

export interface GroupNotice {
  id: string;
  senderId: number;
  senderName: string;
  time: number;
  text: string;
  imageUrls: string[];
  confirmRequired: boolean;
  readCount: number;
  readByMe: boolean;
  pinned: boolean;
}

export interface GroupAlbum {
  id: string;
  name: string;
  desc: string;
  coverUrl: string;
  count: number;
  creatorId: number;
  creatorName: string;
  updatedAt: number;
}

export interface GroupAlbumMedia {
  id: string;
  thumbUrl: string;
  url: string;
  width: number;
  height: number;
  isVideo: boolean;
  videoUrl: string;
  uploaderId: number;
  uploaderName: string;
  time: number;
  batchId: string;
}

export interface GroupEssence {
  seq: number;
  senderId: number;
  senderName: string;
  operatorName: string;
  time: number;
  message: MessageRow | null;
  text: string;
  imageUrls: string[];
}

export interface GroupFolder {
  id: string;
  name: string;
  fileCount: number;
  modifyTime: number;
  creatorName: string;
}

export interface GroupFile {
  id: string;
  busid: number;
  name: string;
  size: number;
  modifyTime: number;
  deadTime: number;
  uploaderId: number;
  uploaderName: string;
  downloadCount: number;
  sha256: string | null;
}

type Ob11 = Record<string, unknown>;

export class GroupContentService {
  private readonly fetching = new Map<string, Promise<{ sha256: string; size: number; mime: string | null }>>();

  constructor(
    private readonly db: Db,
    private readonly media: Pick<MediaService, 'storeBlob' | 'getBlob'>,
    private readonly upstream: () => Pick<UpstreamHub, 'call' | 'isConnected'> | null,
    private readonly opts: { maxFileBytes?: number; logger?: Logger } = {},
  ) {}

  async notices(accountId: number, groupId: number): Promise<GroupNotice[]> {
    const qq = await this.qqAccountOf(accountId);
    // 先用网页接口的原始数据（带自己是否已读、置顶的公告）；插件不支持时退回 OneBot 的。
    const raw = await this.upstream()
      ?.call<{ feeds?: Ob11[]; inst?: Ob11[] }>(qq, 'x.group_notices', { groupId: String(groupId) }, 30_000)
      .catch(() => null);
    if (raw && (raw.feeds?.length || raw.inst?.length)) {
      const all = [...(raw.inst ?? []).map((f) => ({ f, pinned: true })), ...(raw.feeds ?? []).map((f) => ({ f, pinned: false }))];
      const seen = new Set<string>();
      const uniq = all.filter(({ f }) => {
        const id = String(f.fid ?? '');
        if (!id || seen.has(id)) return false;
        seen.add(id);
        return true;
      });
      const names = await this.names(qq, groupId, uniq.map(({ f }) => int(f.u)));
      return uniq
        .map(({ f, pinned }) => {
          const msg = (f.msg ?? {}) as { text?: string; pics?: { id?: string }[] };
          const settings = (f.settings ?? {}) as { confirm_required?: number };
          const senderId = int(f.u);
          return {
            id: String(f.fid),
            senderId,
            senderName: names.get(senderId) ?? String(senderId),
            time: int(f.pubt),
            text: decodeEntities(String(msg.text ?? '')),
            imageUrls: (msg.pics ?? []).filter((p) => p.id).map((p) => `https://gdynamic.qpic.cn/gdynamic/${p.id}/628`),
            confirmRequired: settings.confirm_required === 1,
            readCount: int(f.read_num),
            readByMe: int(f.is_read) === 1,
            pinned,
          };
        })
        .sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.time - a.time);
    }
    const list = (await this.ob11<Ob11[]>(qq, '_get_group_notice', { group_id: String(groupId) })) ?? [];
    const names = await this.names(qq, groupId, list.map((n) => int(n.sender_id)));
    return list.map((n) => {
      const message = (n.message ?? {}) as { text?: string; images?: { id?: string }[]; image?: { id?: string }[] };
      const images = message.images?.length ? message.images : (message.image ?? []);
      const settings = (n.settings ?? {}) as { confirm_required?: number };
      const senderId = int(n.sender_id);
      return {
        id: String(n.notice_id ?? ''),
        senderId,
        senderName: names.get(senderId) ?? String(senderId),
        time: int(n.publish_time),
        text: decodeEntities(String(message.text ?? '')),
        imageUrls: images.filter((i) => i.id).map((i) => `https://gdynamic.qpic.cn/gdynamic/${i.id}/628`),
        confirmRequired: settings.confirm_required === 1,
        readCount: int(n.read_num),
        readByMe: false,
        pinned: false,
      };
    });
  }

  async albums(accountId: number, groupId: number): Promise<GroupAlbum[]> {
    const qq = await this.qqAccountOf(accountId);
    const res = await this.ob11<Ob11>(qq, 'get_qun_album_list', { group_id: String(groupId) });
    const list = (Array.isArray(res?.album_list) ? res.album_list : Array.isArray(res) ? res : []) as Ob11[];
    return list.map((a) => {
      const cover = (a.cover ?? {}) as { image?: AlbumImage };
      const creator = (a.creator ?? {}) as { uin?: string; nick?: string };
      return {
        id: String(a.album_id ?? ''),
        name: String(a.name ?? ''),
        desc: String(a.desc ?? '').trim(),
        coverUrl: albumUrl(cover.image, 'thumb'),
        count: int(a.upload_number),
        creatorId: int(creator.uin),
        creatorName: String(creator.nick ?? ''),
        updatedAt: int(a.last_upload_time) || int(a.modify_time),
      };
    });
  }

  async albumMedia(
    accountId: number,
    groupId: number,
    albumId: string,
    cursor: string,
  ): Promise<{ media: GroupAlbumMedia[]; nextCursor: string; hasMore: boolean; albumName: string }> {
    const qq = await this.qqAccountOf(accountId);
    const res = await this.ob11<Ob11>(qq, 'get_group_album_media_list', {
      group_id: String(groupId),
      album_id: albumId,
      ...(cursor ? { attach_info: cursor } : {}),
    });
    const list = (Array.isArray(res?.media_list) ? res.media_list : []) as Ob11[];
    return {
      media: list.map((m) => {
        const image = (m.image ?? undefined) as AlbumImage | undefined;
        const video = (m.video ?? null) as { cover?: AlbumImage; url?: string; video_url?: string; width?: number; height?: number } | null;
        const user = (m.upload_user ?? {}) as { uin?: string; nick?: string };
        const pic = video?.cover ?? image;
        const big = albumBest(pic);
        return {
          id: String(pic?.lloc ?? m.lloc ?? ''),
          thumbUrl: albumUrl(pic, 'thumb'),
          url: big.url,
          width: big.width,
          height: big.height,
          isVideo: Boolean(video),
          videoUrl: String(video?.url ?? video?.video_url ?? ''),
          uploaderId: int(m.uploader ?? user.uin),
          uploaderName: String(user.nick ?? ''),
          time: int(m.upload_time),
          batchId: String(m.batch_id ?? ''),
        };
      }),
      nextCursor: typeof res?.next_attach_info === 'string' ? res.next_attach_info : '',
      hasMore: res?.next_has_more === true,
      albumName: String(((res?.album ?? {}) as { name?: string }).name ?? ''),
    };
  }

  async essence(accountId: number, groupId: number): Promise<GroupEssence[]> {
    const qq = await this.qqAccountOf(accountId);
    const list = (await this.ob11<Ob11[]>(qq, 'get_essence_msg_list', { group_id: String(groupId) })) ?? [];
    const chat = await maybeOne<{ id: number }>(
      this.db,
      sql`select id from chats where qq_account_id = ${qq} and scene = 'group' and peer_id = ${groupId}`,
    );
    const seqs = list.map((e) => int(e.msg_seq)).filter((s) => s > 0);
    const archived = new Map<number, MessageRow>();
    if (chat && seqs.length > 0) {
      for (const r of await rows(this.db, sql`select ${MESSAGE_COLUMNS} from messages where chat_id = ${chat.id} and seq in ${sqlList(seqs)}`)) {
        const m = toMessage(r);
        archived.set(m.seq, m);
      }
    }
    return list
      .map((e) => {
        const seq = int(e.msg_seq);
        const content = Array.isArray(e.content) ? (e.content as { type?: string; data?: Record<string, unknown> }[]) : [];
        return {
          seq,
          senderId: int(e.sender_id),
          senderName: String(e.sender_nick ?? ''),
          operatorName: String(e.operator_nick ?? ''),
          time: int(e.operator_time),
          message: archived.get(seq) ?? null,
          text: content
            .map((c) => (c.type === 'text' ? String(c.data?.text ?? '') : c.type === 'face' ? '[表情]' : c.type === 'image' ? '' : `[${c.type}]`))
            .join(''),
          imageUrls: content.filter((c) => c.type === 'image' && c.data?.url).map((c) => String(c.data!.url)),
        };
      })
      .sort((a, b) => b.time - a.time);
  }

  async files(accountId: number, groupId: number, folderId: string): Promise<{ folders: GroupFolder[]; files: GroupFile[] }> {
    const qq = await this.qqAccountOf(accountId);
    const res = folderId
      ? await this.ob11<Ob11>(qq, 'get_group_files_by_folder', { group_id: String(groupId), folder_id: folderId, file_count: 1000 })
      : await this.ob11<Ob11>(qq, 'get_group_root_files', { group_id: String(groupId), file_count: 1000 });
    const rawFiles = (Array.isArray(res?.files) ? res.files : []) as Ob11[];
    const rawFolders = (Array.isArray(res?.folders) ? res.folders : []) as Ob11[];
    const ids = rawFiles.map((f) => String(f.file_id ?? '')).filter(Boolean);
    const known = new Map<string, string>();
    if (ids.length > 0) {
      for (const r of await rows<{ file_id: string; sha256: string }>(
        this.db,
        sql`select g.file_id, g.sha256 from group_file_blobs g join blobs b on b.sha256 = g.sha256
             where g.qq_account_id = ${qq} and g.group_id = ${groupId} and g.file_id in ${sqlList(ids)} and b.state = 'present'`,
      )) {
        known.set(r.file_id, r.sha256);
      }
    }
    return {
      folders: rawFolders.map((f) => ({
        id: String(f.folder_id ?? ''),
        name: String(f.folder_name ?? ''),
        fileCount: int(f.total_file_count),
        modifyTime: int(f.modify_time) || int(f.create_time),
        creatorName: String(f.creator_name ?? ''),
      })),
      files: rawFiles
        .map((f) => {
          const id = String(f.file_id ?? '');
          return {
            id,
            busid: int(f.busid),
            name: String(f.file_name ?? ''),
            size: int(f.file_size) || int(f.size),
            modifyTime: int(f.modify_time) || int(f.upload_time),
            deadTime: int(f.dead_time),
            uploaderId: int(f.uploader),
            uploaderName: String(f.uploader_name ?? ''),
            downloadCount: int(f.download_times),
            sha256: known.get(id) ?? null,
          };
        })
        .sort((a, b) => b.modifyTime - a.modifyTime),
    };
  }

  /** 下载群文件到服务端（同一个文件同时只下一次；下过的直接返回）。 */
  async fetchFile(accountId: number, groupId: number, fileId: string, busid: number, name: string) {
    const qq = await this.qqAccountOf(accountId);
    const done = await maybeOne<{ sha256: string; size: number; mime: string | null }>(
      this.db,
      sql`select b.sha256, b.size, b.mime from group_file_blobs g join blobs b on b.sha256 = g.sha256
           where g.qq_account_id = ${qq} and g.group_id = ${groupId} and g.file_id = ${fileId} and b.state = 'present'`,
    );
    if (done) return done;
    const key = `${qq}:${groupId}:${fileId}`;
    const running = this.fetching.get(key);
    if (running) return running;
    const task = this.download(qq, groupId, fileId, busid, name).finally(() => this.fetching.delete(key));
    this.fetching.set(key, task);
    return task;
  }

  private async download(qq: number, groupId: number, fileId: string, busid: number, name: string) {
    const res = await this.ob11<{ url?: string }>(qq, 'get_group_file_url', { group_id: String(groupId), file_id: fileId, busid });
    if (!res?.url) throw new GroupContentError('unavailable', 'QQ did not give a download link (the file may have expired)');
    const url = res.url.endsWith('fname=') ? res.url + encodeURIComponent(name) : res.url;
    const response = await fetch(url, { signal: AbortSignal.timeout(15 * 60_000) });
    if (!response.ok || !response.body) throw new GroupContentError('unavailable', `download failed: HTTP ${response.status}`);
    const blob = await this.media.storeBlob(Readable.fromWeb(response.body as import('node:stream/web').ReadableStream<Uint8Array>), {
      kind: 'file',
      maxBytes: this.opts.maxFileBytes ?? 2 * 1024 * 1024 * 1024,
    });
    await this.db.transaction(async (tx) => {
      await tx.execute(
        sql`insert into group_file_blobs (qq_account_id, group_id, file_id, sha256, name)
            values (${qq}, ${groupId}, ${fileId}, ${blob.sha256}, ${name})
            on conflict (qq_account_id, group_id, file_id) do update set sha256 = excluded.sha256, name = excluded.name`,
      );
      // 计入这个群的存储占用。
      const chat = await maybeOne<{ id: number }>(tx, sql`select id from chats where qq_account_id = ${qq} and scene = 'group' and peer_id = ${groupId}`);
      if (chat) await addUsage(tx, chat.id, blob.sha256);
    });
    this.opts.logger?.info({ groupId, fileId, size: blob.size }, 'group file downloaded');
    return { sha256: blob.sha256, size: blob.size, mime: blob.mime };
  }

  /** 群名片 > 昵称（公告只给了号码）。 */
  private async names(qq: number, groupId: number, ids: number[]): Promise<Map<number, string>> {
    const out = new Map<number, string>();
    if (ids.length === 0) return out;
    for (const m of await rows<{ user_id: number; card: string | null; nickname: string | null }>(
      this.db,
      sql`select user_id, card, nickname from group_members where qq_account_id = ${qq} and group_id = ${groupId} and user_id in ${sqlList([...new Set(ids)])}`,
    )) {
      const n = m.card || m.nickname;
      if (n) out.set(m.user_id, n);
    }
    return out;
  }

  private async qqAccountOf(accountId: number): Promise<number> {
    const row = await maybeOne<{ id: number }>(this.db, sql`select id from qq_accounts where account_id = ${accountId} order by id limit 1`);
    if (!row) throw new GroupContentError('not_found', 'no QQ account is linked');
    return row.id;
  }

  private async ob11<T>(qq: number, name: string, params: Record<string, unknown>): Promise<T | null> {
    const hub = this.upstream();
    if (!hub?.isConnected(qq)) throw new GroupContentError('offline', 'QQ is offline');
    return (await hub.call<T>(qq, 'ob11', { name, params }, 60_000)) ?? null;
  }
}

function int(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : 0;
}

/** 公告正文里的 &#10; 之类的 HTML 实体。 */
export function decodeEntities(text: string): string {
  return text
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n: string) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}


interface AlbumImage {
  lloc?: string;
  photo_url?: { spec?: number; url?: { url?: string; width?: number; height?: number } }[];
  default_url?: { url?: string; width?: number; height?: number };
}

/** 去掉链接里 # 后面的统计参数。 */
function cleanAlbumUrl(url: string | undefined): string {
  return (url ?? '').split('#')[0]!.replace(/^http:/, 'https:');
}

/** 相册图片的小图（约 400px，列表、封面用）。 */
function albumUrl(image: AlbumImage | undefined, _size: 'thumb'): string {
  if (!image) return '';
  const mid = image.photo_url?.find((p) => (p.url?.width ?? 0) >= 300 && (p.url?.width ?? 0) <= 800);
  return cleanAlbumUrl(mid?.url?.url ?? image.default_url?.url);
}

/** 相册图片的原图（最大的那个尺寸）。 */
function albumBest(image: AlbumImage | undefined): { url: string; width: number; height: number } {
  if (!image) return { url: '', width: 0, height: 0 };
  const best = [...(image.photo_url ?? [])].sort((a, b) => (b.url?.width ?? 0) - (a.url?.width ?? 0))[0]?.url ?? image.default_url;
  return { url: cleanAlbumUrl(best?.url), width: best?.width ?? 0, height: best?.height ?? 0 };
}
