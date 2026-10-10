import sharp from 'sharp';
import { describe, expect, it } from 'vitest';
import { deriveImage } from '../src/media/variants.ts';

describe('deriveImage', () => {
  it('still makes a thumbnail from a JPEG that was cut off mid-download', async () => {
    const full = await sharp({ create: { width: 800, height: 600, channels: 3, background: '#4080c0' } })
      .jpeg({ quality: 90 })
      .toBuffer();
    const truncated = full.subarray(0, Math.floor(full.length * 0.6));
    const out = await deriveImage(truncated);
    expect(out).not.toBeNull();
    expect((await sharp(out!.thumb).metadata()).width).toBeGreaterThan(0);
  });
});
