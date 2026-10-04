// QQ 侧的音频输入输出。生产用 PulseAudio（parec / pacat，见 deploy/qq/pulse.pa 的虚拟设备）；
// 测试用纯内存实现。网关本身只依赖这两个接口，所以换平台（docs/design.md 5.8）只需换实现。
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { CHANNELS, FRAME_MS, PcmFramer, SAMPLE_RATE, ToneGenerator } from './pcm.ts';

/** QQ 的声音（通话对方说话）→ 网关。 */
export interface AudioCapture {
  frames(signal: AbortSignal): AsyncIterable<Int16Array>;
}

/** 网关 → QQ 的麦克风（我方说话）。 */
export interface AudioPlayback {
  write(frame: Int16Array): void;
  close(): Promise<void>;
}

export interface PulseOptions {
  /** 例如 unix:/run/qqbridge/pulse/native */
  server: string;
  /** 读取的 source，默认 qq_speaker.monitor。 */
  captureDevice?: string;
  /** 写入的 sink，默认 qq_mic。 */
  playbackDevice?: string;
  captureLatencyMs?: number;
  playbackLatencyMs?: number;
}

const pulseArgs = (device: string, latencyMs: number) => [
  `--device=${device}`,
  '--format=s16le',
  `--rate=${SAMPLE_RATE}`,
  `--channels=${CHANNELS}`,
  `--latency-msec=${latencyMs}`,
  '--raw',
];

/** 用 parec 读取 qq_speaker.monitor（QQ 播放出来的通话声音）。 */
export class PulseCapture implements AudioCapture {
  constructor(private readonly opts: PulseOptions) {}

  async *frames(signal: AbortSignal): AsyncIterable<Int16Array> {
    const proc = spawn('parec', pulseArgs(this.opts.captureDevice ?? 'qq_speaker.monitor', this.opts.captureLatencyMs ?? 20), {
      env: { ...process.env, PULSE_SERVER: this.opts.server },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const onAbort = () => proc.kill('SIGTERM');
    signal.addEventListener('abort', onAbort, { once: true });
    const framer = new PcmFramer();
    try {
      for await (const chunk of proc.stdout) {
        for (const frame of framer.push(chunk as Buffer)) yield frame;
        if (signal.aborted) break;
      }
    } finally {
      signal.removeEventListener('abort', onAbort);
      proc.kill('SIGTERM');
    }
  }
}

/**
 * 用 pacat 写入 qq_mic（经 remap 后成为 QQ 的默认麦克风 qq_mic_source）。
 *
 * 延迟控制：管道和 pacat 内部的积压对我们不可见，而两端都按实时速度进出，一旦积压就会变成永久延迟
 * （实测 pacat 建流期间堆积的约 400ms 会一直留着）。所以：
 *   1. 流建好之前到达的帧直接丢弃；
 *   2. 之后按挂钟记账：已写入的音频时长最多只能领先实际经过的时间 maxAheadMs，超出就丢帧；
 *   3. 落后（对端断流、Pulse 欠载）时重新对齐时钟，避免恢复后突发写入。
 */
export class PulsePlayback implements AudioPlayback {
  private readonly proc: ChildProcessWithoutNullStreams;
  private readonly maxAheadMs: number;
  private closed = false;
  private readyAt: number | null = null;
  private writtenMs = 0;
  private readyWaiters: (() => void)[] = [];
  readonly stats = { written: 0, droppedBeforeReady: 0, droppedAhead: 0, realigned: 0 };

  constructor(opts: PulseOptions & { maxAheadMs?: number }) {
    this.maxAheadMs = opts.maxAheadMs ?? 60;
    this.proc = spawn(
      'pacat',
      ['--playback', '--verbose', ...pulseArgs(opts.playbackDevice ?? 'qq_mic', opts.playbackLatencyMs ?? 40)],
      { env: { ...process.env, PULSE_SERVER: opts.server }, stdio: ['pipe', 'pipe', 'pipe'] },
    );
    this.proc.stdin.on('error', () => undefined);
    let banner = '';
    this.proc.stderr.on('data', (chunk: Buffer) => {
      if (this.readyAt !== null) return;
      banner += chunk.toString('utf8');
      if (banner.includes('Stream successfully created')) {
        this.readyAt = performance.now();
        for (const resolve of this.readyWaiters.splice(0)) resolve();
      }
    });
  }

  /** pacat 的播放流建好后 resolve。 */
  ready(): Promise<void> {
    if (this.readyAt !== null) return Promise.resolve();
    return new Promise((resolve) => this.readyWaiters.push(resolve));
  }

  write(frame: Int16Array): void {
    if (this.closed) return;
    if (this.readyAt === null) {
      this.stats.droppedBeforeReady += 1;
      return;
    }
    const elapsed = performance.now() - this.readyAt;
    if (this.writtenMs < elapsed - FRAME_MS) {
      // 落后于实时（Pulse 已经在播静音）：从现在重新记账。
      this.writtenMs = elapsed;
      this.stats.realigned += 1;
    }
    if (this.writtenMs - elapsed > this.maxAheadMs) {
      this.stats.droppedAhead += 1;
      return;
    }
    this.proc.stdin.write(Buffer.from(frame.buffer, frame.byteOffset, frame.byteLength));
    this.writtenMs += (frame.length / CHANNELS / SAMPLE_RATE) * 1000;
    this.stats.written += 1;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    for (const resolve of this.readyWaiters.splice(0)) resolve();
    this.proc.stdin.end();
    this.proc.kill('SIGTERM');
  }
}

/** 测试用：按实时节奏产生测试音，可以在指定时刻插入一段"标记音"用于测延迟。 */
export class ToneCapture implements AudioCapture {
  constructor(
    private readonly frequency: number,
    private readonly opts: {
      markerFrequency?: number;
      markerAtMs?: number;
      markerMs?: number;
      /** 标记音第一帧送出的时刻（performance.now()），用于测端到端延迟。 */
      onMarker?: (at: number) => void;
    } = {},
  ) {}

  async *frames(signal: AbortSignal): AsyncIterable<Int16Array> {
    const tone = new ToneGenerator(this.frequency);
    const marker = this.opts.markerFrequency ? new ToneGenerator(this.opts.markerFrequency) : null;
    const start = performance.now();
    let n = 0;
    let markerReported = false;
    while (!signal.aborted) {
      const elapsed = n * FRAME_MS;
      const inMarker =
        marker && this.opts.markerAtMs !== undefined && elapsed >= this.opts.markerAtMs && elapsed < this.opts.markerAtMs + (this.opts.markerMs ?? 200);
      if (inMarker && !markerReported) {
        markerReported = true;
        this.opts.onMarker?.(performance.now());
      }
      yield inMarker ? marker.next() : tone.next();
      n += 1;
      const wait = start + n * FRAME_MS - performance.now();
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
    }
  }
}

/** 测试用：收集写入的帧及其到达时间。 */
export class CollectPlayback implements AudioPlayback {
  readonly frames: { at: number; data: Int16Array }[] = [];

  write(frame: Int16Array): void {
    this.frames.push({ at: performance.now(), data: frame.slice() });
  }

  async close(): Promise<void> {}
}
