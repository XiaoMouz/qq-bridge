// 上传（docs/design.md 4.6 第三道去重"秒传"）：
//   1. 客户端先算好 sha256 调 PrepareUpload：服务端已有 → 秒传，不用上传；
//   2. 否则拿到上传地址，按 tus 1.0 核心协议上传：HEAD 查进度，PATCH 从 Upload-Offset 处续传；
//   3. 传完后校验 sha256，进入内容寻址存储（与 QQ 下载来的内容共用同一份）。
// 同一账号同一内容只有一个进行中的上传：App 重启、换网络后再调 PrepareUpload 会拿到同一个地址和已传进度。
import { randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { Transform, type Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, type Db } from '../db/client.ts';
import type { MediaProcessor } from './processing.ts';
import type { MediaService } from './service.ts';
import { HashMismatchError } from './store.ts';

export class UploadError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export interface UploadStatus {
  id: string;
  offset: number;
  size: number;
}

export type PrepareResult = { exists: true } | ({ exists: false } & UploadStatus);

const SHA256 = /^[0-9a-f]{64}$/;

export class UploadService {
  /** 同一个上传的 PATCH 串行处理（单进程部署）。 */
  private readonly locks = new Map<string, Promise<unknown>>();

  constructor(
    private readonly db: Db,
    private readonly media: MediaService,
    private readonly dir: string,
    private readonly maxBytes = 1024 * 1024 * 1024,
    private readonly processor: MediaProcessor | null = null,
  ) {}

  async prepare(accountId: number, req: { sha256: string; size: number; mime?: string; name?: string }): Promise<PrepareResult> {
    if (!SHA256.test(req.sha256)) throw new UploadError(400, 'invalid sha256');
    if (!Number.isSafeInteger(req.size) || req.size <= 0) throw new UploadError(400, 'invalid size');
    if (req.size > this.maxBytes) throw new UploadError(413, `upload exceeds ${this.maxBytes} bytes`);
    if (await this.media.hasContent(req.sha256, req.size)) return { exists: true };
    const row = await one<{ id: string; offset: number; size: number }>(
      this.db,
      sql`insert into uploads (id, account_id, sha256, size, mime, name)
          values (${randomUUID()}, ${accountId}, ${req.sha256}, ${req.size}, ${req.mime || null}, ${req.name || null})
          on conflict (account_id, sha256) do update
             set size = case when uploads.size = excluded.size then uploads.size else excluded.size end,
                 "offset" = case when uploads.size = excluded.size then uploads."offset" else 0 end,
                 mime = coalesce(excluded.mime, uploads.mime),
                 name = coalesce(excluded.name, uploads.name),
                 updated_at = now()
          returning id, "offset", size`,
    );
    return { exists: false, id: row.id, offset: row.offset, size: row.size };
  }

  async status(accountId: number, id: string): Promise<UploadStatus | null> {
    const row = await maybeOne<{ id: string; offset: number; size: number }>(
      this.db,
      sql`select id, "offset", size from uploads where id = ${id} and account_id = ${accountId}`,
    );
    return row ? { id: row.id, offset: row.offset, size: row.size } : null;
  }

  /**
   * 从 offset 处追加一段内容（tus PATCH）。连接中途断开时，已收到的部分照样保留，客户端用 HEAD 查到进度后续传。
   * 收齐后校验 sha256 并入库，返回 sha256。
   */
  append(accountId: number, id: string, offset: number, body: Readable): Promise<{ offset: number; size: number; sha256?: string }> {
    const previous = this.locks.get(id) ?? Promise.resolve();
    const task = previous.catch(() => undefined).then(() => this.appendLocked(accountId, id, offset, body));
    this.locks.set(id, task);
    const release = () => {
      if (this.locks.get(id) === task) this.locks.delete(id);
    };
    task.then(release, release); // 失败由调用方处理；这里只负责释放锁，不产生未处理的 rejection
    return task;
  }

  /** 清理很久没有进展的上传（连同临时文件）。 */
  async cleanup(olderThanMs = 24 * 3600_000): Promise<number> {
    const stale = await rows<{ id: string }>(
      this.db,
      sql`delete from uploads where updated_at < now() - make_interval(secs => ${olderThanMs / 1000}) returning id`,
    );
    for (const { id } of stale) await fs.rm(this.partFile(id), { force: true });
    return stale.length;
  }

  private async appendLocked(accountId: number, id: string, offset: number, body: Readable) {
    const upload = await maybeOne<{ sha256: string; size: number; offset: number; mime: string | null }>(
      this.db,
      sql`select sha256, size, "offset", mime from uploads where id = ${id} and account_id = ${accountId}`,
    );
    if (!upload) {
      body.resume();
      throw new UploadError(404, 'upload not found');
    }
    if (offset !== upload.offset) {
      body.resume();
      throw new UploadError(409, `offset mismatch: server has ${upload.offset}`);
    }
    await fs.mkdir(this.dir, { recursive: true });
    const file = this.partFile(id);
    // 上次可能在写入中途崩溃：文件可能比记录的进度长，以数据库为准。
    const handle = await fs.open(file, 'a+');
    try {
      await handle.truncate(upload.offset);
    } finally {
      await handle.close();
    }

    let received = 0;
    const limit = upload.size - upload.offset;
    const counter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        if (received + chunk.length > limit) return callback(new UploadError(413, 'upload exceeds declared length'));
        received += chunk.length;
        callback(null, chunk);
      },
    });
    let streamError: unknown = null;
    try {
      await pipeline(body, counter, createWriteStream(file, { flags: 'a' }));
    } catch (error) {
      streamError = error; // 客户端中途断开等：保留已写入的部分
    }
    const newOffset = upload.offset + received;
    await this.db.execute(sql`update uploads set "offset" = ${newOffset}, updated_at = now() where id = ${id}`);
    if (streamError instanceof UploadError) throw streamError;
    if (streamError && newOffset < upload.size) throw new UploadError(400, 'upload interrupted');

    if (newOffset < upload.size) return { offset: newOffset, size: upload.size };
    return { offset: newOffset, size: upload.size, sha256: await this.finalize(id, upload) };
  }

  /** 校验并入库。无论成功与否这次上传都结束了：内容与声明不符时客户端需要重新开始。 */
  private async finalize(id: string, upload: { sha256: string; size: number; mime: string | null }): Promise<string> {
    const file = this.partFile(id);
    try {
      const blob = await this.media.storeBlob(createReadStream(file), {
        kind: kindOf(upload.mime),
        ...(upload.mime ? { mime: upload.mime } : {}),
        expectedSha256: upload.sha256,
      });
      // 发出去的图片 / 语音 / 视频经 QQ 回到会话时会按 md5 复用这份内容：提前生成缩略图、可播放版本等。
      await this.processor?.process(blob.sha256, kindOf(blob.mime));
      return blob.sha256;
    } catch (error) {
      if (error instanceof HashMismatchError) throw new UploadError(460, 'checksum mismatch');
      throw error;
    } finally {
      await this.db.execute(sql`delete from uploads where id = ${id}`);
      await fs.rm(file, { force: true });
    }
  }

  private partFile(id: string): string {
    if (!/^[0-9a-f-]{36}$/.test(id)) throw new UploadError(404, 'upload not found');
    return path.join(this.dir, `${id}.part`);
  }
}

function kindOf(mime: string | null): string {
  if (!mime) return 'file';
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('audio/')) return 'audio';
  return 'file';
}
