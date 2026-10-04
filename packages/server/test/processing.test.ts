// 媒体派生版本：语音转 AAC + 波形、视频封面、上传后的缩略图，以及按内容识别类型。
// 样本都是现场生成的（silk-wasm 编码正弦波、ffmpeg 测试图案），不用任何真实聊天内容。
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import sharp from 'sharp';
import { encode as encodeSilk } from 'silk-wasm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { one } from '../src/db/client.ts';
import { ffmpegAvailable, runFfmpeg } from '../src/media/ffmpeg.ts';
import { MediaProcessor, moovLayout, waveformOf, WAVEFORM_BARS } from '../src/media/processing.ts';
import { MediaService } from '../src/media/service.ts';
import { sniffMime } from '../src/media/sniff.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { UploadService } from '../src/media/upload.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';

let t: TestDb;
let root: string;
let media: MediaService;
let processor: MediaProcessor;
const hasFfmpeg = await ffmpegAvailable();

beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-proc-'));
  media = new MediaService(t.db, new LocalFsBackend(root));
  processor = new MediaProcessor(t.db, media);
});

afterAll(async () => {
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

/** 一段 s16le 单声道正弦波：前一半安静、后一半响亮，波形应当前低后高。 */
function sine(seconds: number, rate: number): Buffer {
  const n = Math.floor(seconds * rate);
  const pcm = Buffer.alloc(n * 2);
  for (let i = 0; i < n; i++) {
    const amp = i < n / 2 ? 1500 : 20000;
    pcm.writeInt16LE(Math.round(amp * Math.sin((2 * Math.PI * 440 * i) / rate)), i * 2);
  }
  return pcm;
}

async function blobRow(sha256: string) {
  return one<{ mime: string | null; duration_ms: number | null; waveform: string | null; width: number | null; height: number | null }>(
    t.db,
    sql`select mime, duration_ms, waveform, width, height from blobs where sha256 = ${sha256}`,
  );
}

async function readBlob(sha256: string): Promise<Buffer> {
  const blob = await media.getBlob(sha256);
  const chunks: Buffer[] = [];
  for await (const chunk of await media.openBlob(blob!)) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}

describe('content type sniffing', () => {
  it('recognises the formats QQ actually sends, regardless of the declared Content-Type', () => {
    expect(sniffMime(Buffer.from('#!AMR\n\x0c\x85', 'latin1'))).toBe('audio/amr');
    expect(sniffMime(Buffer.from('\x02#!SILK_V3\x0c', 'latin1'))).toBe('audio/silk');
    expect(sniffMime(Buffer.from('#!SILK_V3', 'latin1'))).toBe('audio/silk');
    expect(sniffMime(Buffer.from('\x00\x00\x00\x20ftypisom\x00\x00\x02\x00', 'latin1'))).toBe('video/mp4');
    expect(sniffMime(Buffer.from('\x00\x00\x00\x14ftypqt  ', 'latin1'))).toBe('video/quicktime');
    expect(sniffMime(Buffer.from('\x00\x00\x00\x18ftypheic', 'latin1'))).toBe('image/heic');
    expect(sniffMime(Buffer.from('\x00\x00\x00\x20ftypM4A ', 'latin1'))).toBe('audio/mp4');
    expect(sniffMime(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe('image/jpeg');
    expect(sniffMime(Buffer.from('GIF89a', 'latin1'))).toBe('image/gif');
    expect(sniffMime(Buffer.from('RIFF\x00\x00\x00\x00WEBPVP8 ', 'latin1'))).toBe('image/webp');
    expect(sniffMime(Buffer.from('ID3\x04', 'latin1'))).toBe('audio/mpeg');
    expect(sniffMime(Buffer.from('%PDF-1.7', 'latin1'))).toBe('application/pdf');
    expect(sniffMime(Buffer.from('hello world', 'latin1'))).toBeNull();
  });

  it('stores the sniffed type and corrects a wrong one stored earlier', async () => {
    const amr = Buffer.concat([Buffer.from('#!AMR\n', 'latin1'), Buffer.alloc(64, 7)]);
    const stored = await media.storeBlob(Readable.from([amr]), { kind: 'audio', mime: 'audio/mp3' });
    expect(stored.mime).toBe('audio/amr');
    await t.db.execute(sql`update blobs set mime = 'application/octet-stream' where sha256 = ${stored.sha256}`);
    await media.storeBlob(Readable.from([amr]), { kind: 'audio', mime: 'application/octet-stream' });
    expect((await blobRow(stored.sha256)).mime).toBe('audio/amr');
  });
});

describe('waveform', () => {
  it('normalises 64 bars to 0–255 and follows the loudness', () => {
    const wave = waveformOf(sine(2, 8000));
    expect(wave.length).toBe(WAVEFORM_BARS);
    expect(Math.max(...wave)).toBe(255);
    expect(wave[5]!).toBeLessThan(40); // 安静的前半段
    expect(wave[50]!).toBeGreaterThan(200); // 响亮的后半段
    expect([...waveformOf(Buffer.alloc(0))]).toEqual(new Array(WAVEFORM_BARS).fill(0));
  });
});

describe.skipIf(!hasFfmpeg)('MediaProcessor (ffmpeg)', () => {
  it('turns a QQ silk voice message into an AAC file the iPhone can play, with a waveform', async () => {
    const silk = Buffer.from((await encodeSilk(sine(2, 24000), 24000)).data);
    const stored = await media.storeBlob(Readable.from([silk]), { kind: 'audio', mime: 'audio/mp3' });
    expect(stored.mime).toBe('audio/silk');

    const info = await processor.process(stored.sha256, 'audio');
    expect(info.playableSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(info.playableSha256).not.toBe(stored.sha256);
    expect(Buffer.from(info.waveform!, 'base64')).toHaveLength(WAVEFORM_BARS);
    expect((await blobRow(info.playableSha256!)).mime).toBe('audio/mp4');
    const row = await blobRow(stored.sha256);
    expect(row.duration_ms).toBeGreaterThan(1800);
    expect(row.duration_ms).toBeLessThan(2300);

    // 转出来的文件能被解码，时长对得上。
    const m4a = await readBlob(info.playableSha256!);
    const pcm = await runFfmpeg(['-i', 'pipe:0', '-f', 's16le', '-ac', '1', '-ar', '8000', 'pipe:1'], { input: m4a });
    expect(pcm.length / 2 / 8000).toBeGreaterThan(1.8);

    // 第二次直接复用，不再转码。
    const blobsBefore = await one<{ n: number }>(t.db, sql`select count(*)::int as n from blobs`);
    expect(await processor.process(stored.sha256, 'audio')).toEqual(info);
    expect(await one<{ n: number }>(t.db, sql`select count(*)::int as n from blobs`)).toEqual(blobsBefore);
  });

  it('keeps already playable audio (mp3) as is and only adds the waveform', async () => {
    const mp3 = await runFfmpeg(['-f', 's16le', '-ar', '16000', '-ac', '1', '-i', 'pipe:0', '-c:a', 'libmp3lame', '-b:a', '32k', '-f', 'mp3', 'pipe:1'], {
      input: sine(1, 16000),
    });
    const stored = await media.storeBlob(Readable.from([mp3]), { kind: 'audio' });
    expect(stored.mime).toBe('audio/mpeg');
    const info = await processor.process(stored.sha256, 'audio');
    expect(info.playableSha256).toBe(stored.sha256);
    expect(Buffer.from(info.waveform!, 'base64')).toHaveLength(WAVEFORM_BARS);
  });

  it('grabs a cover frame from a video whose index sits at the end of the file', async () => {
    const out = path.join(root, 'test.mp4');
    await runFfmpeg(['-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10', '-t', '1', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-y', out]);
    const video = await fs.readFile(out);
    expect(video.subarray(4, 8).toString('latin1')).toBe('ftyp');
    const stored = await media.storeBlob(Readable.from([video]), { kind: 'video', mime: 'application/octet-stream' });
    expect(stored.mime).toBe('video/mp4');

    const info = await processor.process(stored.sha256, 'video');
    expect(info).toMatchObject({ width: 320, height: 240 });
    expect(info.thumbSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(info.thumbhash).toBeTruthy();
    const cover = await sharp(await readBlob(info.thumbSha256!)).metadata();
    expect(cover).toMatchObject({ format: 'webp', width: 320, height: 240 });

    // 流式播放版本：只换封装，moov 挪到开头，原件不动。
    expect(await moovLayout(out)).toBe('end');
    expect(info.playableSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(info.playableSha256).not.toBe(stored.sha256);
    const streamFile = path.join(root, 'stream.mp4');
    await fs.writeFile(streamFile, await readBlob(info.playableSha256!));
    expect(await moovLayout(streamFile)).toBe('front');
    expect(Math.abs((await fs.stat(streamFile)).size - video.length)).toBeLessThan(1024); // 没有重新编码
    expect(await processor.existing(stored.sha256)).toMatchObject({ playableSha256: info.playableSha256 });

    // 已经是 faststart 的视频直接用原件。
    const fast = await media.storeBlob(Readable.from([await fs.readFile(streamFile)]), { kind: 'video' });
    expect((await processor.process(fast.sha256, 'video')).playableSha256).toBe(fast.sha256);
  });
});

describe('uploads', () => {
  it('prepares thumbnails as soon as an image upload completes', async () => {
    const png = await sharp({ create: { width: 900, height: 600, channels: 3, background: '#0af' } }).png().toBuffer();
    const sha256 = createHash('sha256').update(png).digest('hex');
    const uploads = new UploadService(t.db, media, path.join(root, 'uploads'), 10 * 1024 * 1024, processor);
    const { id } = await t.db.execute(sql`insert into accounts (username, password_hash) values ('u', 'x') returning id`).then((r) => r.rows[0] as { id: number });
    const prepared = await uploads.prepare(id, { sha256, size: png.length, mime: 'image/png' });
    if (prepared.exists) throw new Error('unexpected instant upload');
    await uploads.append(id, prepared.id, 0, Readable.from([png]));
    const derived = await processor.existing(sha256);
    expect(derived).toMatchObject({ width: 900, height: 600 });
    expect(derived.thumbSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(derived.previewSha256).toMatch(/^[0-9a-f]{64}$/);
  });
});
