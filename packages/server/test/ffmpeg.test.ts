import { describe, expect, it } from 'vitest';
import { parseStreams } from '../src/media/ffmpeg.ts';

describe('parseStreams', () => {
  it('reads the stream list ffmpeg prints, including codecs it cannot identify', () => {
    // 取自一段 iPhone 视频：空间音频 apac 和 mebx 元数据轨 ffmpeg 都认不出（none）。
    const stderr = `Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'x.mov':
  Duration: 00:00:05.00, start: 0.000000, bitrate: 17000 kb/s
  Stream #0:0[0x1](und): Video: hevc (Main 10) (hvc1 / 0x31637668), yuv420p10le, 1920x1080, 30 fps (default)
  Stream #0:1[0x2](und): Audio: none (apac / 0x63617061), 48000 Hz, 5.0, 460 kb/s
  Stream #0:2[0x3](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 138 kb/s (default)
  Stream #0:3[0x4](und): Data: none (mebx / 0x7862656D), 2 kb/s (default)
At least one output file must be specified`;
    expect(parseStreams(stderr)).toEqual([
      { index: 0, type: 'video', codec: 'hevc' },
      { index: 1, type: 'audio', codec: 'none' },
      { index: 2, type: 'audio', codec: 'aac' },
      { index: 3, type: 'data', codec: 'none' },
    ]);
  });
});
