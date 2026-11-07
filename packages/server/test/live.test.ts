// 边下边播：读到还没下到的部分时等，下到了接着给；下载失败时读的一方报错（2026-11-08）。
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { LiveDownloads, moovAfterMdat } from '../src/media/live.ts';

const collect = async (stream: AsyncIterable<Buffer>) => {
  const parts: Buffer[] = [];
  for await (const p of stream) parts.push(p);
  return Buffer.concat(parts).toString();
};

describe('live downloads', () => {
  it('serves ranges as bytes arrive', async () => {
    const live = new LiveDownloads(await mkdtemp(path.join(tmpdir(), 'live-')));
    const spool = await live.start(10, 'video/mp4');
    await spool.write(Buffer.from('abcd'));
    const head = collect(live.read(spool.id, 0, 3));
    expect(await head).toBe('abcd');
    const rest = collect(live.read(spool.id, 2, 9));
    await spool.write(Buffer.from('efg'));
    await spool.write(Buffer.from('hij'));
    spool.finish(true);
    expect(await rest).toBe('cdefghij');
    expect(live.info(spool.id)).toEqual({ total: 10, mime: 'video/mp4', failed: false });
  });

  it('fails readers when the download fails', async () => {
    const live = new LiveDownloads(await mkdtemp(path.join(tmpdir(), 'live-')));
    const spool = await live.start(10, 'video/mp4');
    await spool.write(Buffer.from('ab'));
    const reading = collect(live.read(spool.id, 0, 9));
    spool.finish(false);
    await expect(reading).rejects.toThrow();
  });

  it('serves the tail first for videos whose index is at the end', async () => {
    const live = new LiveDownloads(await mkdtemp(path.join(tmpdir(), 'live-')));
    const spool = await live.start(10, 'video/mp4');
    spool.startTail(7);
    await spool.writeTail(Buffer.from('hij'));
    expect(await collect(live.read(spool.id, 7, 9))).toBe('hij');
    const middle = collect(live.read(spool.id, 0, 6));
    await spool.write(Buffer.from('abcdefg'));
    expect(await middle).toBe('abcdefg');
    spool.finish(true);
  });

  it('finds moov after mdat from the first boxes', () => {
    const box = (size: number, type: string) => {
      const b = Buffer.alloc(8);
      b.writeUInt32BE(size, 0);
      b.write(type, 4, 'latin1');
      return b;
    };
    const late = Buffer.concat([box(24, 'ftyp'), Buffer.alloc(16), box(1000, 'mdat')]);
    expect(moovAfterMdat(late, 5000)).toBe(1024);
    const fast = Buffer.concat([box(24, 'ftyp'), Buffer.alloc(16), box(300, 'moov')]);
    expect(moovAfterMdat(fast, 5000)).toBeNull();
    expect(moovAfterMdat(box(24, 'ftyp'), 5000)).toBeUndefined();
  });
});
