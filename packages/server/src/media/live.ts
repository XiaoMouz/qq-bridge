// 正在从 QQ 下载的视频：边下边写一份临时文件，客户端用签名链接 /media/live/<id>/video.mp4 按 Range 读，
// 还没下到的部分等它下到再给（AVPlayer 边下边播）。2026-11-08 用户反馈大视频要等服务端整个下完才开始播放。
// 下完后再留 30 分钟（播放器可能还在读、拖进度），之后删掉；正式内容照常按 sha256 入库。
import { randomUUID } from 'node:crypto';
import { createWriteStream, promises as fs, type WriteStream } from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';

interface Entry {
  path: string;
  total: number;
  mime: string;
  received: number;
  done: boolean;
  failed: boolean;
  out: WriteStream;
  waiters: Set<() => void>;
}

export interface LiveSpool {
  id: string;
  write(chunk: Uint8Array): Promise<void>;
  finish(ok: boolean): void;
}

const KEEP_AFTER_DONE_MS = 30 * 60_000;
/** 读的人等新数据最多等这么久（QQ 那边卡住时不让连接一直挂着）。 */
const WAIT_MS = 60_000;

export class LiveDownloads {
  private readonly entries = new Map<string, Entry>();

  constructor(private readonly dir: string) {}

  async start(total: number, mime: string): Promise<LiveSpool> {
    await fs.mkdir(this.dir, { recursive: true });
    const id = randomUUID();
    const file = path.join(this.dir, `live-${id}`);
    const entry: Entry = { path: file, total, mime, received: 0, done: false, failed: false, out: createWriteStream(file, { mode: 0o600 }), waiters: new Set() };
    this.entries.set(id, entry);
    const wake = () => {
      for (const w of entry.waiters) w();
      entry.waiters.clear();
    };
    return {
      id,
      write: (chunk) =>
        new Promise<void>((resolve, reject) => {
          entry.out.write(chunk, (error) => {
            if (error) return reject(error);
            entry.received += chunk.length;
            wake();
            resolve();
          });
        }),
      finish: (ok) => {
        entry.done = true;
        entry.failed = !ok;
        entry.out.end(() => wake());
        setTimeout(() => this.drop(id), ok ? KEEP_AFTER_DONE_MS : 5_000).unref();
      },
    };
  }

  info(id: string): { total: number; mime: string; failed: boolean } | null {
    const e = this.entries.get(id);
    return e ? { total: e.total, mime: e.mime, failed: e.failed } : null;
  }

  /** 读 [start, end]：还没下到的等它下到；下载失败或等太久就报错断开。 */
  read(id: string, start: number, end: number): Readable {
    const entry = this.entries.get(id);
    const waitFor = (offset: number) =>
      new Promise<void>((resolve, reject) => {
        if (!entry || entry.failed) return reject(new Error('live download failed'));
        if (entry.received > offset || entry.done) return resolve();
        const timer = setTimeout(() => {
          entry.waiters.delete(done);
          reject(new Error('live download stalled'));
        }, WAIT_MS);
        const done = () => {
          clearTimeout(timer);
          resolve();
        };
        entry.waiters.add(done);
      });
    return Readable.from(
      (async function* () {
        if (!entry) throw new Error('live download gone');
        const handle = await fs.open(entry.path, 'r');
        try {
          let pos = start;
          while (pos <= end) {
            await waitFor(pos);
            if (entry.failed) throw new Error('live download failed');
            const available = Math.min(entry.received - 1, end);
            if (available < pos) {
              if (entry.done) throw new Error('live download ended early');
              continue;
            }
            const length = Math.min(available - pos + 1, 256 * 1024);
            const buffer = Buffer.alloc(length);
            const { bytesRead } = await handle.read(buffer, 0, length, pos);
            if (bytesRead === 0) continue;
            pos += bytesRead;
            yield buffer.subarray(0, bytesRead);
          }
        } finally {
          await handle.close();
        }
      })(),
    );
  }

  private drop(id: string) {
    const e = this.entries.get(id);
    if (!e) return;
    this.entries.delete(id);
    void fs.rm(e.path, { force: true });
  }
}
