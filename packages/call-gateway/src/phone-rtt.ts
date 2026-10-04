// 全链路往返时延测量：本进程扮演 iPhone，发出的声音经 LiveKit → 网关 → PulseAudio（回环）→ 网关 → LiveKit 回到自己。
// 所有计时都在同一个时钟上，往返时延 / 2 约等于单向的额外延迟。
import {
  AudioFrame,
  AudioSource,
  AudioStream,
  LocalAudioTrack,
  Room,
  RoomEvent,
  TrackKind,
  TrackPublishOptions,
  TrackSource,
} from '@livekit/rtc-node';
import { FRAME_MS, SAMPLE_RATE, ToneGenerator, concatFrames, toneRatio } from './pcm.ts';
import { mintRoomToken } from './token.ts';

const BASE_HZ = 660;
const MARKER_HZ = 1500;
const PERIOD_MS = 2000;
const MARKER_OFFSET_MS = 1000;
const MARKER_MS = 200;

export async function measurePhoneRtt(opts: {
  url: string;
  room: string;
  seconds: number;
  apiKey: string;
  apiSecret: string;
}): Promise<{ rttMs: number[]; medianRttMs: number | null; heardFrames: number; baseToneRatio: number }> {
  const token = await mintRoomToken({ apiKey: opts.apiKey, apiSecret: opts.apiSecret, room: opts.room, identity: 'phone-rtt' });
  const room = new Room();
  const heard: { at: number; data: Int16Array }[] = [];
  room.on(RoomEvent.TrackSubscribed, (track) => {
    if (track.kind !== TrackKind.KIND_AUDIO) return;
    const reader = new AudioStream(track, { sampleRate: SAMPLE_RATE, numChannels: 1, frameSizeMs: FRAME_MS }).getReader();
    void (async () => {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        heard.push({ at: performance.now(), data: value.data.slice() });
      }
    })().catch(() => undefined);
  });
  await room.connect(opts.url, token, { autoSubscribe: true, dynacast: false });
  const source = new AudioSource(SAMPLE_RATE, 1, 200);
  const publish = new TrackPublishOptions();
  publish.source = TrackSource.SOURCE_MICROPHONE;
  await room.localParticipant!.publishTrack(LocalAudioTrack.createAudioTrack('mic', source), publish);

  const base = new ToneGenerator(BASE_HZ);
  const marker = new ToneGenerator(MARKER_HZ);
  const markerTimes: number[] = [];
  const start = performance.now();
  const total = Math.round((opts.seconds * 1000) / FRAME_MS);
  for (let i = 0; i < total; i++) {
    const phase = (i * FRAME_MS) % PERIOD_MS;
    const inMarker = phase >= MARKER_OFFSET_MS && phase < MARKER_OFFSET_MS + MARKER_MS;
    if (inMarker && phase === MARKER_OFFSET_MS) markerTimes.push(performance.now());
    await source.captureFrame(new AudioFrame(inMarker ? marker.next() : base.next(), SAMPLE_RATE, 1, 480));
    const wait = start + (i + 1) * FRAME_MS - performance.now();
    if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  }
  const sendEnd = performance.now();
  await new Promise((resolve) => setTimeout(resolve, 1500));
  await room.disconnect();

  const rttMs: number[] = [];
  for (const sentAt of markerTimes) {
    const hit = heard.find((f) => f.at >= sentAt && f.at < sentAt + 1500 && toneRatio(f.data, MARKER_HZ) > 0.6);
    if (hit) rttMs.push(Math.round(hit.at - sentAt));
  }
  const sorted = [...rttMs].sort((a, b) => a - b);
  // 只取发送期间、最长的一段连续不含标记音的音频（拼接不连续的帧会造成频谱泄漏，让结果偏低）。
  const steady = concatFrames(longestRun(heard.filter((f) => f.at < sendEnd), (f) => toneRatio(f.data, MARKER_HZ) < 0.3).map((f) => f.data));
  return {
    rttMs,
    medianRttMs: sorted.length ? sorted[Math.floor(sorted.length / 2)]! : null,
    heardFrames: heard.length,
    baseToneRatio: toneRatio(steady, BASE_HZ),
  };
}

function longestRun<T>(items: readonly T[], keep: (item: T) => boolean): T[] {
  let best: T[] = [];
  let current: T[] = [];
  for (const item of items) {
    if (keep(item)) {
      current.push(item);
      if (current.length > best.length) best = current;
    } else {
      current = [];
    }
  }
  // 去掉首尾各 10 帧，避开标记音前后的过渡。
  return best.length > 40 ? best.slice(10, -10) : best;
}
