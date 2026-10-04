// 通话音频桥的集成测试：真实 LiveKit 服务端 + 网关（QQ 侧用测试音代替 PulseAudio）+ 一个"假 iPhone"参与者。
// 验证两个方向都能听到对方，并用标记音测量端到端延迟（docs/design.md 5.6：语音额外延迟目标 < 250ms）。
import {
  AudioFrame,
  AudioSource,
  AudioStream,
  dispose,
  LocalAudioTrack,
  Room,
  RoomEvent,
  TrackKind,
  TrackPublishOptions,
  TrackSource,
} from '@livekit/rtc-node';
import { afterAll, describe, expect, inject, it } from 'vitest';
import { CollectPlayback, ToneCapture } from '../src/audio-io.ts';
import { CallAudioBridge } from '../src/bridge.ts';
import { concatFrames, toneRatio } from '../src/pcm.ts';
import { mintRoomToken } from '../src/token.ts';
import { LIVEKIT_KEY, LIVEKIT_SECRET } from './livekit-setup.ts';

const url = inject('livekitUrl');
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

afterAll(async () => {
  await dispose();
});

/** 找到第一帧"主要是 frequency"的帧的到达时间。 */
function firstArrival(frames: { at: number; data: Int16Array }[], frequency: number): number | null {
  for (const f of frames) if (toneRatio(f.data, frequency) > 0.6) return f.at;
  return null;
}

describe.skipIf(!url)('CallAudioBridge over a real LiveKit server', () => {
  it('carries audio in both directions with low latency', async () => {
    const room = `call-${Date.now()}`;
    const [gatewayToken, phoneToken] = await Promise.all([
      mintRoomToken({ apiKey: LIVEKIT_KEY, apiSecret: LIVEKIT_SECRET, room, identity: 'qq-gateway' }),
      mintRoomToken({ apiKey: LIVEKIT_KEY, apiSecret: LIVEKIT_SECRET, room, identity: 'iphone' }),
    ]);

    // QQ 侧：440Hz，第 2.5 秒起插入 300ms 的 1000Hz 标记音。
    let qqMarkerAt = 0;
    const playback = new CollectPlayback();
    const bridge = new CallAudioBridge({
      url,
      token: gatewayToken,
      capture: new ToneCapture(440, { markerFrequency: 1000, markerAtMs: 2500, markerMs: 300, onMarker: (t) => (qqMarkerAt = t) }),
      playback,
    });
    await bridge.start();

    // 假 iPhone：收听网关的轨道，同时发布 660Hz（带 1500Hz 标记音）。
    const phone = new Room();
    const heardByPhone: { at: number; data: Int16Array }[] = [];
    phone.on(RoomEvent.TrackSubscribed, (track) => {
      if (track.kind !== TrackKind.KIND_AUDIO) return;
      const reader = new AudioStream(track, { sampleRate: 48_000, numChannels: 1, frameSizeMs: 10 }).getReader();
      void (async () => {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          heardByPhone.push({ at: performance.now(), data: value.data.slice() });
        }
      })().catch(() => undefined);
    });
    await phone.connect(url, phoneToken, { autoSubscribe: true, dynacast: false });
    const micSource = new AudioSource(48_000, 1, 200);
    const options = new TrackPublishOptions();
    options.source = TrackSource.SOURCE_MICROPHONE;
    await phone.localParticipant!.publishTrack(LocalAudioTrack.createAudioTrack('mic', micSource), options);

    let phoneMarkerAt = 0;
    const abort = new AbortController();
    const phoneMic = new ToneCapture(660, { markerFrequency: 1500, markerAtMs: 2500, markerMs: 300, onMarker: (t) => (phoneMarkerAt = t) });
    const pump = (async () => {
      for await (const frame of phoneMic.frames(abort.signal)) {
        await micSource.captureFrame(new AudioFrame(frame, 48_000, 1, frame.length));
      }
    })();

    await sleep(6000);
    const remoteDuringCall = bridge.stats.remoteIdentity;
    abort.abort();
    await pump;
    await phone.disconnect();
    // 对端离开后网关应清掉当前对端，以便下一位参与者接上。
    await sleep(500);
    expect(bridge.stats.remoteIdentity).toBeNull();
    await bridge.stop();

    // 1) iPhone 听到了 QQ 侧的 440Hz（看最后 1 秒）。
    expect(heardByPhone.length).toBeGreaterThan(200);
    expect(toneRatio(concatFrames(heardByPhone.slice(-100).map((f) => f.data)), 440)).toBeGreaterThan(0.5);
    // 2) QQ 的麦克风收到了 iPhone 的 660Hz。
    expect(remoteDuringCall).toBe('iphone');
    expect(playback.frames.length).toBeGreaterThan(200);
    expect(toneRatio(concatFrames(playback.frames.slice(-100).map((f) => f.data)), 660)).toBeGreaterThan(0.5);

    // 3) 端到端延迟：标记音从送出到对端第一次听到。
    const qqToPhone = firstArrival(heardByPhone, 1000);
    const phoneToQq = firstArrival(playback.frames, 1500);
    expect(qqToPhone).not.toBeNull();
    expect(phoneToQq).not.toBeNull();
    const latencyDown = qqToPhone! - qqMarkerAt;
    const latencyUp = phoneToQq! - phoneMarkerAt;
    console.log(`[latency] QQ→iPhone ${latencyDown.toFixed(0)}ms, iPhone→QQ ${latencyUp.toFixed(0)}ms`);
    expect(latencyDown).toBeLessThan(400);
    expect(latencyUp).toBeLessThan(400);
  });
});
