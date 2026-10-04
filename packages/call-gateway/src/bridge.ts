// 通话音频桥（docs/design.md 5.2）：网关以"QQ 端"身份加入 LiveKit 房间。
//   QQ 的声音（AudioCapture）→ 发布为 qq-audio 轨道 → iPhone 收听；
//   iPhone 的麦克风轨道 → AudioStream → AudioPlayback → QQ 的麦克风。
// 同一时间只桥接一个对端（最先发布音频的参与者，通常是 iPhone）；它离开后换成下一个。
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
  type RemoteParticipant,
  type RemoteTrack,
} from '@livekit/rtc-node';
import type { AudioCapture, AudioPlayback } from './audio-io.ts';
import { CHANNELS, FRAME_MS, SAMPLE_RATE } from './pcm.ts';

export interface BridgeOptions {
  url: string;
  token: string;
  capture: AudioCapture;
  playback: AudioPlayback;
  /** AudioSource 的队列长度（毫秒）。 */
  sourceQueueMs?: number;
  /**
   * 发送队列超过这个时长就丢弃新帧，而不是等待。等待会把反压传回 parec 的管道，
   * 管道里的积压会变成永久延迟（见 audio-io.ts 的说明）。
   */
  maxSendBacklogMs?: number;
  onLog?: (event: string, detail?: Record<string, unknown>) => void;
}

export interface BridgeStats {
  framesSent: number;
  framesDropped: number;
  framesReceived: number;
  remoteIdentity: string | null;
  connected: boolean;
}

export class CallAudioBridge {
  private readonly room = new Room();
  private readonly abort = new AbortController();
  private readonly source: AudioSource;
  private readonly readers = new Set<ReadableStreamDefaultReader<AudioFrame>>();
  private pump: Promise<void> | null = null;
  readonly stats: BridgeStats = { framesSent: 0, framesDropped: 0, framesReceived: 0, remoteIdentity: null, connected: false };

  constructor(private readonly opts: BridgeOptions) {
    this.source = new AudioSource(SAMPLE_RATE, CHANNELS, opts.sourceQueueMs ?? 200);
  }

  async start(): Promise<void> {
    this.room.on(RoomEvent.TrackSubscribed, (track, _publication, participant) => this.onTrack(track, participant));
    this.room.on(RoomEvent.ParticipantDisconnected, (participant) => {
      if (participant.identity === this.stats.remoteIdentity) {
        this.log('remote left', { identity: participant.identity });
        this.stats.remoteIdentity = null;
      }
    });
    this.room.on(RoomEvent.Disconnected, () => {
      this.stats.connected = false;
    });

    await this.room.connect(this.opts.url, this.opts.token, { autoSubscribe: true, dynacast: false });
    this.stats.connected = true;

    const track = LocalAudioTrack.createAudioTrack('qq-audio', this.source);
    const options = new TrackPublishOptions();
    options.source = TrackSource.SOURCE_MICROPHONE;
    await this.room.localParticipant!.publishTrack(track, options);
    this.log('published', { room: this.room.name });

    // 房间里已经有人在说话（例如 iPhone 先入会）的情况由 autoSubscribe + TrackSubscribed 处理。
    this.pump = this.pumpCapture();
  }

  async stop(): Promise<void> {
    if (this.abort.signal.aborted) return;
    this.abort.abort();
    for (const reader of this.readers) await reader.cancel().catch(() => undefined);
    await this.pump?.catch(() => undefined);
    await this.room.disconnect();
    await this.opts.playback.close();
    this.stats.connected = false;
  }

  private async pumpCapture(): Promise<void> {
    try {
      const maxBacklog = this.opts.maxSendBacklogMs ?? 60;
      for await (const frame of this.opts.capture.frames(this.abort.signal)) {
        if (this.abort.signal.aborted) break;
        if (this.source.queuedDuration > maxBacklog) {
          this.stats.framesDropped += 1;
          continue;
        }
        await this.source.captureFrame(new AudioFrame(frame, SAMPLE_RATE, CHANNELS, frame.length / CHANNELS));
        this.stats.framesSent += 1;
      }
    } catch (error) {
      if (!this.abort.signal.aborted) this.log('capture failed', { error: String(error) });
    }
  }

  private onTrack(track: RemoteTrack, participant: RemoteParticipant): void {
    if (track.kind !== TrackKind.KIND_AUDIO) return;
    if (this.stats.remoteIdentity && this.stats.remoteIdentity !== participant.identity) {
      this.log('ignoring extra remote audio', { identity: participant.identity });
      return;
    }
    this.stats.remoteIdentity = participant.identity;
    this.log('remote audio subscribed', { identity: participant.identity });
    const stream = new AudioStream(track, { sampleRate: SAMPLE_RATE, numChannels: CHANNELS, frameSizeMs: FRAME_MS });
    const reader = stream.getReader();
    this.readers.add(reader);
    void (async () => {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done || this.abort.signal.aborted) break;
          if (participant.identity !== this.stats.remoteIdentity) continue;
          this.opts.playback.write(value.data);
          this.stats.framesReceived += 1;
        }
      } catch (error) {
        if (!this.abort.signal.aborted) this.log('remote audio failed', { error: String(error) });
      } finally {
        this.readers.delete(reader);
      }
    })();
  }

  private log(event: string, detail?: Record<string, unknown>): void {
    this.opts.onLog?.(event, detail);
  }
}
