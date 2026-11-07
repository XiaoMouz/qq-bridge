// 正在从 QQ 下载的视频：边下边写一份临时文件，客户端用签名链接 /media/live/<id>/video.mp4 按 Range 读，
// 还没下到的部分等它下到再给（AVPlayer 边下边播）。2026-11-08 用户反馈大视频要等服务端整个下完才开始播放。
// 索引（moov）在文件末尾的视频（2026-11-08 抽查最近 40 个里有 14 个），播放器要先读末尾；下载任务另用 Range
// 把末尾那段先取回来写到对应位置（writeAt），这里按「从头连续下到的部分 + 末尾那段」判断哪些字节能给。
// 下完后再留 30 分钟（播放器可能还在读、拖进度），之后删掉；正式内容照常按 sha256 入库。
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import type { FileHandle } from 'node:fs/promises';
import path from 'node:path';
import { Readable } from 'node:stream';

interface Entry {
  path: string;
  file: FileHandle;
  total: number;
  mime: string;
  /** 从头连续写到的字节数。 */
  received: number;
  /** 末尾那段：从 start 起已写到的字节数。 */
  tail: { start: number; filled: number } | null;
  done: boolean;
  failed: boolean;
  waiters: Set<() => void>;
}

export interface LiveSpool {
  id: string;
  /** 从头顺序写。 */
  write(chunk: Uint8Array): Promise<void>;
  /** 末尾那段（moov 在后面的视频）：从 start 起顺序写。 */
  startTail(start: number): void;
  writeTail(chunk: Uint8Array): Promise<void>;
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
    const handle = await fs.open(file, 'w+', 0o600);
    const entry: Entry = { path: file, file: handle, total, mime, received: 0, tail: null, done: false, failed: false, waiters: new Set() };
    this.entries.set(id, entry);
    const wake = () => {
      for (const w of entry.waiters) w();
      entry.waiters.clear();
    };
    return {
      id,
      write: async (chunk) => {
        await handle.write(chunk, 0, chunk.length, entry.received);
        entry.received += chunk.length;
        wake();
      },
      startTail: (start) => {
        if (!entry.tail && start > entry.received && start < total) entry.tail = { start, filled: 0 };
      },
      writeTail: async (chunk) => {
        const tail = entry.tail;
        if (!tail) return;
        await handle.write(chunk, 0, chunk.length, tail.start + tail.filled);
        tail.filled += chunk.length;
        wake();
      },
      finish: (ok) => {
        entry.done = true;
        entry.failed = !ok;
        wake();
        setTimeout(() => this.drop(id), ok ? KEEP_AFTER_DONE_MS : 5_000).unref();
      },
    };
  }

  info(id: string): { total: number; mime: string; failed: boolean } | null {
    const e = this.entries.get(id);
    return e ? { total: e.total, mime: e.mime, failed: e.failed } : null;
  }

  /** 从 pos 起连续能给到哪个字节（含）；还没有时为 -1。 */
  private static availableEnd(e: Entry, pos: number): number {
    if (pos < e.received) return e.received - 1;
    if (e.tail && pos >= e.tail.start && pos < e.tail.start + e.tail.filled) return e.tail.start + e.tail.filled - 1;
    return -1;
  }

  /** 读 [start, end]：还没下到的等它下到；下载失败或等太久就报错断开。 */
  read(id: string, start: number, end: number): Readable {
    const entry = this.entries.get(id);
    const waitChange = () =>
      new Promise<void>((resolve, reject) => {
        if (!entry || entry.failed) return reject(new Error('live download failed'));
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
        let pos = start;
        while (pos <= end) {
          if (entry.failed) throw new Error('live download failed');
          const available = Math.min(LiveDownloads.availableEnd(entry, pos), end);
          if (available < pos) {
            if (entry.done) throw new Error('live download ended early');
            await waitChange();
            continue;
          }
          const length = Math.min(available - pos + 1, 256 * 1024);
          const buffer = Buffer.alloc(length);
          const { bytesRead } = await entry.file.read(buffer, 0, length, pos);
          if (bytesRead === 0) {
            await waitChange();
            continue;
          }
          pos += bytesRead;
          yield buffer.subarray(0, bytesRead);
        }
      })(),
    );
  }

  private drop(id: string) {
    const e = this.entries.get(id);
    if (!e) return;
    this.entries.delete(id);
    void e.file.close().finally(() => fs.rm(e.path, { force: true }));
  }
}

/**
 * MP4 开头几个盒子：moov 在 mdat 后面时返回 moov 开始的位置（要先取回末尾那段），否则 null。
 * head 是文件开头已收到的字节；读不全（mdat 的头还没到）时返回 undefined，等收到更多再看。
 */
export function moovAfterMdat(head: Uint8Array, total: number): number | null | undefined {
  const view = Buffer.from(head.buffer, head.byteOffset, head.byteLength);
  let pos = 0;
  for (let i = 0; i < 8; i++) {
    if (pos + 8 > view.length) return undefined;
    let size = view.readUInt32BE(pos);
    const type = view.toString('latin1', pos + 4, pos + 8);
    if (size === 1) {
      if (pos + 16 > view.length) return undefined;
      size = Number(view.readBigUInt64BE(pos + 8));
    } else if (size === 0) size = total - pos;
    if (size < 8) return null;
    if (type === 'moov') return null;
    if (type === 'mdat') return pos + size < total ? pos + size : null;
    pos += size;
  }
  return null;
}
