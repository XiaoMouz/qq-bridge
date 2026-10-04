// PulseAudio 通路自检（不需要登录 QQ）：在 QQ 容器的隔离 PulseAudio 上验证网关的两条声音通路。
//   下行：往 qq_speaker 放音（相当于 QQ 播放对方的声音）→ 网关从 qq_speaker.monitor 读到。
//   上行：网关往 qq_mic 写入 → 从 qq_mic_source（QQ 实际使用的麦克风）录到。
// 先放 3 秒基准音让两端的流稳定，再插入 200ms 标记音，测"稳态延迟"（通话中真正感受到的那部分）。
import { PulseCapture, PulsePlayback, type PulseOptions } from './audio-io.ts';
import { FRAME_MS, ToneGenerator, concatFrames, rms, toneRatio } from './pcm.ts';

export interface PathResult {
  ok: boolean;
  tone: number;
  ratio: number;
  rms: number;
  /** 从开始写入到第一次读到有效声音（含建流的冷启动），毫秒。 */
  firstSoundMs: number | null;
  /** 稳态延迟：标记音从写入到读到，毫秒。 */
  steadyLatencyMs: number | null;
  /** pacat 建流耗时，毫秒。 */
  playbackReadyMs: number | null;
  playback: PulsePlayback['stats'];
}

export interface SelftestOptions {
  server: string;
  captureLatencyMs?: number;
  playbackLatencyMs?: number;
}

const BASE_MS = 3000;
const MARKER_MS = 200;
const TAIL_MS = 800;

export async function pulseSelftest(opts: SelftestOptions): Promise<{ downlink: PathResult; uplink: PathResult }> {
  const common = {
    server: opts.server,
    ...(opts.captureLatencyMs ? { captureLatencyMs: opts.captureLatencyMs } : {}),
    ...(opts.playbackLatencyMs ? { playbackLatencyMs: opts.playbackLatencyMs } : {}),
  };
  const downlink = await checkPath({ ...common, playbackDevice: 'qq_speaker', captureDevice: 'qq_speaker.monitor' }, 440, 1000);
  const uplink = await checkPath({ ...common, playbackDevice: 'qq_mic', captureDevice: 'qq_mic_source' }, 660, 1500);
  return { downlink, uplink };
}

async function checkPath(opts: PulseOptions, frequency: number, markerFrequency: number): Promise<PathResult> {
  const abort = new AbortController();
  const captured: { at: number; data: Int16Array }[] = [];
  const capture = new PulseCapture(opts);
  const reading = (async () => {
    for await (const frame of capture.frames(abort.signal)) captured.push({ at: performance.now(), data: frame });
  })();
  await sleep(300); // 让 parec 先连上

  const playback = new PulsePlayback(opts);
  const spawnedAt = performance.now();
  let playbackReadyMs: number | null = null;
  void playback.ready().then(() => (playbackReadyMs = Math.round(performance.now() - spawnedAt)));
  const base = new ToneGenerator(frequency);
  const marker = new ToneGenerator(markerFrequency);
  const start = performance.now();
  let markerAt = 0;
  const total = Math.round((BASE_MS + MARKER_MS + TAIL_MS) / FRAME_MS);
  for (let i = 0; i < total; i++) {
    const t = i * FRAME_MS;
    const inMarker = t >= BASE_MS && t < BASE_MS + MARKER_MS;
    if (inMarker && markerAt === 0) markerAt = performance.now();
    playback.write(inMarker ? marker.next() : base.next());
    const wait = start + (i + 1) * FRAME_MS - performance.now();
    if (wait > 0) await sleep(wait);
  }
  await sleep(1500);
  await playback.close();
  abort.abort();
  await reading.catch(() => undefined);

  const afterStart = captured.filter((f) => f.at >= start);
  const first = afterStart.find((f) => toneRatio(f.data, frequency) > 0.5 && rms(f.data) > 0.05);
  const markerHit = afterStart.find((f) => f.at >= markerAt && toneRatio(f.data, markerFrequency) > 0.6);
  const steady = afterStart.filter((f) => markerHit && f.at < markerHit.at).slice(-100);
  const tail = concatFrames(steady.map((f) => f.data));
  const ratio = toneRatio(tail, frequency);
  const level = rms(tail);
  return {
    ok: ratio > 0.5 && level > 0.05 && Boolean(markerHit),
    tone: frequency,
    ratio,
    rms: level,
    firstSoundMs: first ? Math.round(first.at - start) : null,
    steadyLatencyMs: markerHit ? Math.round(markerHit.at - markerAt) : null,
    playbackReadyMs,
    playback: { ...playback.stats },
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
