import { describe, expect, it } from 'vitest';
import { FRAME_BYTES, PcmFramer, SAMPLES_PER_FRAME, ToneGenerator, concatFrames, rms, toneRatio } from '../src/pcm.ts';

describe('PcmFramer', () => {
  it('cuts arbitrary chunks into exact 10 ms frames and keeps the remainder', () => {
    const framer = new PcmFramer();
    const bytes = Buffer.alloc(FRAME_BYTES * 2 + 100);
    for (let i = 0; i < bytes.length / 2; i++) bytes.writeInt16LE(i % 30000, i * 2);
    const frames = [...framer.push(bytes.subarray(0, 777)), ...framer.push(bytes.subarray(777))];
    expect(frames).toHaveLength(2);
    expect(frames.every((f) => f.length === SAMPLES_PER_FRAME)).toBe(true);
    expect(frames[1]![0]).toBe(SAMPLES_PER_FRAME);
    expect(framer.bufferedBytes).toBe(100);
  });
});

describe('tone helpers', () => {
  it('detect the generated frequency and reject others', () => {
    const tone = new ToneGenerator(440);
    const signal = concatFrames(Array.from({ length: 20 }, () => tone.next()));
    expect(toneRatio(signal, 440)).toBeGreaterThan(0.9);
    expect(toneRatio(signal, 1000)).toBeLessThan(0.05);
    expect(rms(signal)).toBeGreaterThan(0.2);
    expect(rms(new Int16Array(480))).toBe(0);
  });
});
