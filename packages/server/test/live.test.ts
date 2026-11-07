// 边下边播：读到还没下到的部分时等，下到了接着给；下载失败时读的一方报错（2026-11-08）。
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { LiveDownloads } from '../src/media/live.ts';

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
});
