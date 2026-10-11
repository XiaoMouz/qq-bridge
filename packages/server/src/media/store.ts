// 内容寻址存储：文件按 sha256 存放，同一内容只存一份（docs/design.md 4.6）。
// 写入时一边落临时文件一边计算 sha256、md5、前 10 MiB 的 md5（对应 QQ 大文件给的 file10MMd5）。
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { Transform, type Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

export const MD5_HEAD_BYTES = 10 * 1024 * 1024;

export interface StoredObject {
  key: string;
  sha256: string;
  md5: string;
  md5Head: string;
  size: number;
  /** 同样的内容之前已经存在（本次写入被丢弃）。 */
  existed: boolean;
}

export class TooLargeError extends Error {}

/** 内容与声明的 sha256 不一致（上传损坏或客户端算错），不会写进存储。 */
export class HashMismatchError extends Error {}

export interface PutOptions {
  maxBytes?: number;
  /** 期望的 sha256：不一致时丢弃并抛 HashMismatchError。 */
  expectedSha256?: string;
}

/** 已写到临时位置、算好哈希、但还没放进内容寻址存储的对象（两阶段写入）。 */
export interface StagedObject extends Omit<StoredObject, 'existed'> {
  tmpPath: string;
}

export interface StorageBackend {
  /** 一步写入：stage + commit。 */
  put(source: Readable | AsyncIterable<Uint8Array>, opts?: PutOptions): Promise<StoredObject>;
  /** 两阶段写入的第一步：写临时文件并计算哈希（调用方随后 commit 或 discard）。 */
  stage(source: Readable | AsyncIterable<Uint8Array>, opts?: PutOptions): Promise<StagedObject>;
  /** 放进存储；同样内容已存在时丢弃临时文件。调用方应持有该内容的 blobs 行锁，与原件清理互斥。 */
  commit(staged: StagedObject): Promise<{ existed: boolean }>;
  discard(staged: StagedObject): Promise<void>;
  open(key: string, range?: { start: number; end?: number }): Promise<Readable>;
  stat(key: string): Promise<{ size: number } | null>;
  delete(key: string): Promise<void>;
  /** 本地文件路径（本地磁盘存储才有；ffmpeg 读视频需要能回退的文件）。 */
  localPath?(key: string): string | null;
}

export function keyForSha256(sha256: string): string {
  if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error(`invalid sha256: ${sha256}`);
  return `${sha256.slice(0, 2)}/${sha256.slice(2, 4)}/${sha256}`;
}

export class LocalFsBackend implements StorageBackend {
  private readonly blobDir: string;
  private readonly tmpDir: string;

  constructor(readonly root: string) {
    this.blobDir = path.join(root, 'blobs');
    this.tmpDir = path.join(root, 'tmp');
  }

  async put(source: Readable | AsyncIterable<Uint8Array>, opts: PutOptions = {}): Promise<StoredObject> {
    const staged = await this.stage(source, opts);
    const { existed } = await this.commit(staged);
    const { tmpPath: _tmp, ...object } = staged;
    return { ...object, existed };
  }

  async commit(staged: StagedObject): Promise<{ existed: boolean }> {
    const finalPath = path.join(this.blobDir, staged.key);
    if (await exists(finalPath)) {
      await fs.rm(staged.tmpPath, { force: true });
      return { existed: true };
    }
    await fs.mkdir(path.dirname(finalPath), { recursive: true });
    await fs.rename(staged.tmpPath, finalPath);
    return { existed: false };
  }

  async discard(staged: StagedObject): Promise<void> {
    await fs.rm(staged.tmpPath, { force: true });
  }

  async stage(source: Readable | AsyncIterable<Uint8Array>, opts: PutOptions = {}): Promise<StagedObject> {
    await fs.mkdir(this.tmpDir, { recursive: true });
    const tmp = path.join(this.tmpDir, randomUUID());
    const sha256 = createHash('sha256');
    const md5 = createHash('md5');
    const md5Head = createHash('md5');
    let size = 0;
    const maxBytes = opts.maxBytes ?? Number.POSITIVE_INFINITY;
    const hasher = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        if (size > maxBytes) return callback(new TooLargeError(`object exceeds ${maxBytes} bytes`));
        sha256.update(chunk);
        md5.update(chunk);
        const headRemaining = MD5_HEAD_BYTES - (size - chunk.length);
        if (headRemaining > 0) md5Head.update(chunk.subarray(0, Math.min(chunk.length, headRemaining)));
        callback(null, chunk);
      },
    });
    try {
      await pipeline(source, hasher, createWriteStream(tmp, { mode: 0o600 }));
    } catch (error) {
      await fs.rm(tmp, { force: true });
      throw error;
    }
    const digest = sha256.digest('hex');
    if (opts.expectedSha256 && digest !== opts.expectedSha256) {
      await fs.rm(tmp, { force: true });
      throw new HashMismatchError(`content sha256 ${digest} does not match ${opts.expectedSha256}`);
    }
    const key = keyForSha256(digest);
    return { key, sha256: digest, md5: md5.digest('hex'), md5Head: md5Head.digest('hex'), size, tmpPath: tmp };
  }

  async open(key: string, range?: { start: number; end?: number }): Promise<Readable> {
    const file = this.resolve(key);
    await fs.access(file);
    return createReadStream(file, range ? { start: range.start, end: range.end } : undefined);
  }

  async stat(key: string): Promise<{ size: number } | null> {
    try {
      const s = await fs.stat(this.resolve(key));
      return { size: s.size };
    } catch {
      return null;
    }
  }

  async delete(key: string): Promise<void> {
    await fs.rm(this.resolve(key), { force: true });
  }

  localPath(key: string): string {
    return this.resolve(key);
  }

  private resolve(key: string): string {
    const file = path.resolve(this.blobDir, key);
    if (!file.startsWith(this.blobDir + path.sep)) throw new Error(`invalid storage key: ${key}`);
    return file;
  }
}

async function exists(file: string): Promise<boolean> {
  try {
    await fs.access(file);
    return true;
  } catch {
    return false;
  }
}

/** 冷存储所在的盘没挂上（外接硬盘拔了等）。 */
export class StorageUnavailableError extends Error {}

/** 存储根目录里的标记文件：有它才认为盘挂上了。 */
export const STORAGE_MARKER = '.qqbridge-storage';

/**
 * 可拔插的存储（外接硬盘上的冷存储）：根目录里有标记文件才可用，否则一律抛 StorageUnavailableError。
 * 永远不创建根目录本身——盘没挂上时 /Volumes/<盘名> 下的路径会落到系统盘上，绝不能往那里写。
 * 根目录和标记文件由部署时创建（见 README"冷存储"）。
 */
export class RemovableBackend implements StorageBackend {
  private readonly inner: LocalFsBackend;

  constructor(readonly root: string) {
    this.inner = new LocalFsBackend(root);
  }

  available(): boolean {
    return existsSync(path.join(this.root, STORAGE_MARKER));
  }

  private check(): void {
    if (!this.available()) throw new StorageUnavailableError(`storage at ${this.root} is not mounted`);
  }

  async put(source: Readable | AsyncIterable<Uint8Array>, opts?: PutOptions): Promise<StoredObject> {
    this.check();
    return this.inner.put(source, opts);
  }

  async stage(source: Readable | AsyncIterable<Uint8Array>, opts?: PutOptions): Promise<StagedObject> {
    this.check();
    return this.inner.stage(source, opts);
  }

  async commit(staged: StagedObject): Promise<{ existed: boolean }> {
    this.check();
    return this.inner.commit(staged);
  }

  async discard(staged: StagedObject): Promise<void> {
    return this.inner.discard(staged);
  }

  async open(key: string, range?: { start: number; end?: number }): Promise<Readable> {
    this.check();
    return this.inner.open(key, range);
  }

  async stat(key: string): Promise<{ size: number } | null> {
    this.check();
    return this.inner.stat(key);
  }

  async delete(key: string): Promise<void> {
    this.check();
    return this.inner.delete(key);
  }

  localPath(key: string): string | null {
    return this.available() ? this.inner.localPath(key) : null;
  }

  /** 列出存储里所有内容的 sha256（清理孤儿文件用）。 */
  async *keys(): AsyncGenerator<string> {
    this.check();
    const blobs = path.join(this.root, 'blobs');
    for (const a of await fs.readdir(blobs).catch(() => [] as string[])) {
      for (const b of await fs.readdir(path.join(blobs, a)).catch(() => [] as string[])) {
        for (const name of await fs.readdir(path.join(blobs, a, b)).catch(() => [] as string[])) {
          if (/^[0-9a-f]{64}$/.test(name)) yield name;
        }
      }
    }
  }
}
