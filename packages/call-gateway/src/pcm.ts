// PCM 工具：统一使用 48 kHz、单声道、s16le，每帧 10 ms（480 个采样）。
// 语音通话用单声道足够，两端都不需要重采样（PulseAudio 和 WebRTC 内部会处理设备差异）。

export const SAMPLE_RATE = 48_000;
export const CHANNELS = 1;
export const FRAME_MS = 10;
export const SAMPLES_PER_FRAME = (SAMPLE_RATE / 1000) * FRAME_MS;
export const FRAME_BYTES = SAMPLES_PER_FRAME * CHANNELS * 2;

/** 把任意长度的字节块切成整帧（Int16Array），余下的不足一帧的部分留到下次。 */
export class PcmFramer {
  private pending: Buffer = Buffer.alloc(0);

  constructor(private readonly frameBytes = FRAME_BYTES) {}

  push(chunk: Buffer): Int16Array[] {
    this.pending = this.pending.length === 0 ? chunk : Buffer.concat([this.pending, chunk]);
    const frames: Int16Array[] = [];
    while (this.pending.length >= this.frameBytes) {
      const frame = this.pending.subarray(0, this.frameBytes);
      // 复制一份并保证 2 字节对齐（Buffer 可能来自共享池，偏移量不一定对齐）。
      const copy = new Int16Array(this.frameBytes / 2);
      Buffer.from(copy.buffer).set(frame);
      frames.push(copy);
      this.pending = this.pending.subarray(this.frameBytes);
    }
    return frames;
  }

  get bufferedBytes(): number {
    return this.pending.length;
  }
}

/** 正弦测试音（连续调用相位连续）。 */
export class ToneGenerator {
  private phase = 0;

  constructor(
    private readonly frequency: number,
    private readonly amplitude = 0.3,
    private readonly sampleRate = SAMPLE_RATE,
  ) {}

  next(samples = SAMPLES_PER_FRAME): Int16Array {
    const out = new Int16Array(samples);
    const step = (2 * Math.PI * this.frequency) / this.sampleRate;
    for (let i = 0; i < samples; i++) {
      out[i] = Math.round(Math.sin(this.phase) * this.amplitude * 32767);
      this.phase += step;
    }
    this.phase %= 2 * Math.PI;
    return out;
  }
}

/** Goertzel：估计某个频率在一段信号里的能量占比（0~1），用于测试里判断"听到的是不是那个音"。 */
export function toneRatio(samples: Int16Array, frequency: number, sampleRate = SAMPLE_RATE): number {
  if (samples.length === 0) return 0;
  const k = Math.round((samples.length * frequency) / sampleRate);
  const w = (2 * Math.PI * k) / samples.length;
  const coeff = 2 * Math.cos(w);
  let s1 = 0;
  let s2 = 0;
  let total = 0;
  for (const v of samples) {
    const x = v / 32768;
    total += x * x;
    const s0 = x + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  const power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
  return total === 0 ? 0 : (2 * power) / (samples.length * total);
}

export function rms(samples: Int16Array): number {
  if (samples.length === 0) return 0;
  let sum = 0;
  for (const v of samples) sum += (v / 32768) ** 2;
  return Math.sqrt(sum / samples.length);
}

export function concatFrames(frames: readonly Int16Array[]): Int16Array {
  const total = frames.reduce((n, f) => n + f.length, 0);
  const out = new Int16Array(total);
  let offset = 0;
  for (const f of frames) {
    out.set(f, offset);
    offset += f.length;
  }
  return out;
}
