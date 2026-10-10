// 派生版本（docs/design.md 4.6"处理与下发"）：
//   图片 / 表情：缩略图（320px）、预览图（1280px）、thumbhash；
//   语音：转成 iPhone 能直接播放的 AAC（m4a），并算出波形（64 个振幅，随消息下发）；
//   视频：取一帧做封面（同样产出缩略图、预览图、thumbhash，宽高即视频宽高）；
//         QQ 的 mp4 索引（moov）在文件末尾，另存一份 faststart 版本（只换封装、不重新编码），
//         播放器拿到开头就能边下边播。
// 同一内容只处理一次（结果记在 blobs 与 blob_variants），同样内容再出现直接复用。
// 处理失败只记日志：原件已经存好，派生版本可以之后用 `cli media:reprocess` 补。
import { createReadStream } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Readable } from 'node:stream';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import sharp from 'sharp';
import { decode as decodeSilk } from 'silk-wasm';
import { maybeOne, rows, type Db } from '../db/client.ts';
import { ffmpegAvailable, runFfmpeg } from './ffmpeg.ts';
import type { BlobRecord, MediaService } from './service.ts';
import { deriveImage, MAX_DERIVE_BYTES } from './variants.ts';

export interface DerivedInfo {
  thumbhash?: string;
  thumbSha256?: string;
  previewSha256?: string;
  width?: number;
  height?: number;
  /** 客户端能直接播放的版本（语音：AAC m4a；本身就能播放时等于原件）。 */
  playableSha256?: string;
  /** 语音波形（base64，64 个 0–255 的振幅）。 */
  waveform?: string;
}

export const WAVEFORM_BARS = 64;
const MAX_AUDIO_BYTES = 20 * 1024 * 1024;
/** iPhone 原生能播放的音频，不用转码。 */
const PLAYABLE_AUDIO = new Set(['audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/wav']);

export interface ProcessorOptions {
  ffmpegPath?: string;
  logger?: Logger;
}

export class MediaProcessor {
  private ffmpeg: Promise<boolean> | null = null;

  constructor(
    private readonly db: Db,
    private readonly media: MediaService,
    private readonly opts: ProcessorOptions = {},
  ) {}

  /** 按类型生成（或复用）派生版本，返回要写进消息媒体信息的字段。出错时返回空对象。 */
  async process(sha256: string, kind: string): Promise<DerivedInfo> {
    try {
      const known = await this.existing(sha256);
      switch (kind) {
        case 'image':
        case 'sticker':
          // 图片不自己生成缩略图 / 预览图：缩略图用 QQ 给的（spec=720），客户端有原图时直接显示原图。只补宽高。
          return known.width ? known : { ...known, ...(await this.imageSize(sha256)) };
        case 'audio':
          return known.playableSha256 ? known : await this.audio(sha256);
        case 'video':
          return known.thumbSha256 && known.playableSha256 ? known : { ...known, ...(await this.video(sha256, known)) };
        default:
          return {};
      }
    } catch (error) {
      this.opts.logger?.warn({ err: error, sha256, kind }, 'media processing failed');
      return {};
    }
  }

  /** 之前处理过的结果。 */
  async existing(sha256: string): Promise<DerivedInfo> {
    const blob = await maybeOne<{ thumbhash: string | null; width: number | null; height: number | null; waveform: string | null }>(
      this.db,
      sql`select thumbhash, width, height, waveform from blobs where sha256 = ${sha256}`,
    );
    const variants = new Map(
      (
        await rows<{ variant: string; variant_sha256: string }>(
          this.db,
          sql`select variant, variant_sha256 from blob_variants where sha256 = ${sha256}`,
        )
      ).map((v) => [v.variant, v.variant_sha256]),
    );
    return compact({
      thumbhash: blob?.thumbhash ?? undefined,
      thumbSha256: variants.get('thumb'),
      previewSha256: variants.get('preview'),
      playableSha256: variants.get('playable'),
      width: blob?.width ?? undefined,
      height: blob?.height ?? undefined,
      waveform: blob?.waveform ?? undefined,
    });
  }

  /** 只读文件头里的宽高（不解码、不重新编码）。 */
  private async imageSize(sha256: string): Promise<DerivedInfo> {
    const blob = await this.media.getBlob(sha256);
    if (!blob || blob.state !== 'present' || blob.size > MAX_DERIVE_BYTES) return {};
    const meta = await sharp(await this.read(blob), { animated: false }).metadata().catch(() => null);
    if (!meta?.width || !meta.height) return {};
    await this.db.execute(sql`update blobs set width = ${meta.width}, height = ${meta.height} where sha256 = ${sha256}`);
    return { width: meta.width, height: meta.height };
  }

  private async audio(sha256: string): Promise<DerivedInfo> {
    const blob = await this.media.getBlob(sha256);
    if (!blob || blob.state !== 'present' || blob.size > MAX_AUDIO_BYTES) return {};
    const input = await this.read(blob);
    const hasFfmpeg = await this.hasFfmpeg();
    let pcm: Buffer;
    let sampleRate: number;
    if (blob.mime === 'audio/silk') {
      sampleRate = 24_000;
      pcm = Buffer.from((await decodeSilk(input, sampleRate)).data);
    } else {
      if (!hasFfmpeg) return {};
      sampleRate = 16_000;
      pcm = await runFfmpeg(['-i', 'pipe:0', '-f', 's16le', '-ac', '1', '-ar', String(sampleRate), 'pipe:1'], this.ff(input));
    }
    const waveform = waveformOf(pcm).toString('base64');
    const durationMs = Math.round((pcm.length / 2 / sampleRate) * 1000);

    let playableSha256: string | undefined;
    if (blob.mime && PLAYABLE_AUDIO.has(blob.mime)) {
      playableSha256 = sha256;
    } else if (hasFfmpeg) {
      // mp4 封装需要可回退的输出，所以先写临时文件；+faststart 让播放器边下边播。
      const out = path.join(os.tmpdir(), `qqbridge-${randomUUID()}.m4a`);
      try {
        await runFfmpeg(
          ['-f', 's16le', '-ar', String(sampleRate), '-ac', '1', '-i', 'pipe:0', '-c:a', 'aac', '-b:a', '32k', '-movflags', '+faststart', '-y', out],
          this.ff(pcm),
        );
        const m4a = await this.media.storeBlob(Readable.from([await fs.readFile(out)]), { kind: 'audio', mime: 'audio/mp4' });
        playableSha256 = m4a.sha256;
      } finally {
        await fs.rm(out, { force: true });
      }
    }
    await this.db.transaction(async (tx) => {
      await tx.execute(sql`update blobs set waveform = ${waveform}, duration_ms = ${durationMs} where sha256 = ${sha256}`);
      if (playableSha256) await upsertVariant(tx, sha256, 'playable', playableSha256);
    });
    return compact({ playableSha256, waveform });
  }

  private async video(sha256: string, known: DerivedInfo): Promise<DerivedInfo> {
    if (!(await this.hasFfmpeg())) return {};
    const blob = await this.media.getBlob(sha256);
    if (!blob || blob.state !== 'present') return {};
    // mp4 的索引可能在文件末尾，ffmpeg 需要能回退读取，所以给文件路径而不是管道。
    return this.withLocalFile(blob, async (file) => {
      const cover = known.thumbSha256 ? {} : await this.videoCover(sha256, file).catch((error) => this.failed(error, sha256, 'cover'));
      const stream = known.playableSha256 ? {} : await this.faststart(sha256, blob).catch((error) => this.failed(error, sha256, 'faststart'));
      return { ...cover, ...stream };
    });
  }

  private async videoCover(sha256: string, file: string): Promise<DerivedInfo> {
    const grab = (args: string[]) => runFfmpeg([...args, '-i', file, '-frames:v', '1', '-f', 'image2pipe', '-c:v', 'png', 'pipe:1'], this.ff());
    let frame = await grab(['-ss', '0.5']).catch(() => Buffer.alloc(0));
    if (frame.length === 0) frame = await grab([]); // 不到 0.5 秒的视频取第一帧
    return this.saveImageDerivatives(sha256, frame);
  }

  /**
   * 视频直接用原件播放：服务端支持 Range，播放器遇到 moov 在末尾的文件会先单独取尾部的索引，
   * 再从头边下边播（实测起播时间和 faststart 版本相同），不必另存一份重新封装的副本。
   */
  private async faststart(sha256: string, blob: BlobRecord): Promise<DerivedInfo> {
    if (blob.mime !== 'video/mp4' && blob.mime !== 'video/quicktime') return {};
    await upsertVariant(this.db, sha256, 'playable', sha256);
    return { playableSha256: sha256 };
  }

  private failed(error: unknown, sha256: string, step: string): DerivedInfo {
    this.opts.logger?.warn({ err: error, sha256, step }, 'video processing step failed');
    return {};
  }

  /** 生成缩略图 / 预览图 / thumbhash 并记下来（视频封面也走这里）。 */
  private async saveImageDerivatives(sha256: string, image: Buffer): Promise<DerivedInfo> {
    const derived = await deriveImage(image);
    if (!derived) return {};
    const thumb = await this.media.storeBlob(Readable.from([derived.thumb]), { kind: 'image', mime: 'image/webp' });
    const preview = derived.preview
      ? await this.media.storeBlob(Readable.from([derived.preview]), { kind: 'image', mime: 'image/webp' })
      : null;
    await this.db.transaction(async (tx) => {
      await tx.execute(
        sql`update blobs set thumbhash = ${derived.thumbhash}, width = ${derived.width}, height = ${derived.height} where sha256 = ${sha256}`,
      );
      await upsertVariant(tx, sha256, 'thumb', thumb.sha256);
      if (preview) await upsertVariant(tx, sha256, 'preview', preview.sha256);
    });
    return compact({
      thumbhash: derived.thumbhash,
      thumbSha256: thumb.sha256,
      previewSha256: preview?.sha256,
      width: derived.width,
      height: derived.height,
    });
  }

  private async read(blob: BlobRecord): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const chunk of await this.media.openBlob(blob)) chunks.push(chunk as Buffer);
    return Buffer.concat(chunks);
  }

  private async withLocalFile<T>(blob: BlobRecord, fn: (file: string) => Promise<T>): Promise<T> {
    const local = this.media.localPath(blob);
    if (local) return fn(local);
    const tmp = path.join(os.tmpdir(), `qqbridge-${randomUUID()}`);
    try {
      await fs.writeFile(tmp, await this.read(blob));
      return await fn(tmp);
    } finally {
      await fs.rm(tmp, { force: true });
    }
  }

  private hasFfmpeg(): Promise<boolean> {
    this.ffmpeg ??= ffmpegAvailable(this.opts.ffmpegPath).then((ok) => {
      if (!ok) this.opts.logger?.warn('ffmpeg not found: voice transcoding and video covers are disabled');
      return ok;
    });
    return this.ffmpeg;
  }

  private ff(input?: Buffer) {
    return { ...(this.opts.ffmpegPath ? { ffmpegPath: this.opts.ffmpegPath } : {}), ...(input ? { input } : {}) };
  }
}

/** 看 mp4 顶层 box 的顺序：moov 在 mdat 之前是 'front'，之后是 'end'；读不出来是 'unknown'。只读 box 头，不读内容。 */
export async function moovLayout(file: string): Promise<'front' | 'end' | 'unknown'> {
  const handle = await fs.open(file, 'r');
  try {
    const { size } = await handle.stat();
    const head = Buffer.alloc(16);
    let offset = 0;
    let sawMdat = false;
    while (offset + 8 <= size) {
      const { bytesRead } = await handle.read(head, 0, 16, offset);
      if (bytesRead < 8) break;
      let boxSize = head.readUInt32BE(0);
      const type = head.toString('latin1', 4, 8);
      if (boxSize === 1) {
        if (bytesRead < 16) break;
        boxSize = Number(head.readBigUInt64BE(8));
      } else if (boxSize === 0) {
        boxSize = size - offset;
      }
      if (type === 'moov') return sawMdat ? 'end' : 'front';
      if (type === 'mdat') sawMdat = true;
      if (boxSize < 8) break;
      offset += boxSize;
    }
    return 'unknown';
  } finally {
    await handle.close();
  }
}

/** 把 PCM（s16le 单声道）分成 64 段，取每段的均方根，按最大值归一到 0–255。 */
export function waveformOf(pcm: Buffer, bars = WAVEFORM_BARS): Buffer {
  const samples = Math.floor(pcm.length / 2);
  const out = Buffer.alloc(bars);
  if (samples === 0) return out;
  const rms = new Array<number>(bars).fill(0);
  for (let b = 0; b < bars; b++) {
    const start = Math.floor((b * samples) / bars);
    const end = Math.max(start + 1, Math.floor(((b + 1) * samples) / bars));
    let sum = 0;
    for (let i = start; i < end && i < samples; i++) {
      const v = pcm.readInt16LE(i * 2);
      sum += v * v;
    }
    rms[b] = Math.sqrt(sum / (end - start));
  }
  const max = Math.max(...rms);
  for (let b = 0; b < bars; b++) out[b] = max > 0 ? Math.round((rms[b]! / max) * 255) : 0;
  return out;
}

async function upsertVariant(tx: { execute: Db['execute'] }, sha256: string, variant: string, variantSha256: string) {
  await tx.execute(
    sql`insert into blob_variants (sha256, variant, variant_sha256) values (${sha256}, ${variant}, ${variantSha256})
        on conflict (sha256, variant) do update set variant_sha256 = excluded.variant_sha256`,
  );
}

function compact(info: { [K in keyof DerivedInfo]: DerivedInfo[K] | undefined }): DerivedInfo {
  return Object.fromEntries(Object.entries(info).filter(([, v]) => v !== undefined && v !== null)) as DerivedInfo;
}
