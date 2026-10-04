import { describe, expect, it } from 'vitest';
import { outgoingMedia, validateOutgoing, type OutgoingSegment } from '../src/outgoing.ts';

const SHA = 'a'.repeat(64);
const SHA2 = 'b'.repeat(64);

describe('validateOutgoing', () => {
  it('accepts rich text with mentions, faces, images and a reply', () => {
    const segments: OutgoingSegment[] = [
      { type: 'mention', userId: 20002 },
      { type: 'text', text: ' 看这个' },
      { type: 'face', faceId: '14' },
      { type: 'image', sha256: SHA },
      { type: 'image', sha256: SHA2, sticker: true },
    ];
    expect(validateOutgoing({ segments, replyToSeq: 41 })).toBeNull();
    expect(outgoingMedia([...segments, { type: 'image', sha256: SHA }])).toEqual([SHA, SHA2]);
  });

  it('requires voice, video and files to be sent on their own, without a reply', () => {
    expect(validateOutgoing({ segments: [{ type: 'file', sha256: SHA, name: '报告.pdf' }] })).toBeNull();
    expect(validateOutgoing({ segments: [{ type: 'record', sha256: SHA }, { type: 'text', text: 'x' }] })).toBe(
      'record must be sent on its own',
    );
    expect(validateOutgoing({ segments: [{ type: 'video', sha256: SHA }], replyToSeq: 3 })).toBe('video cannot reply to a message');
  });

  it('rejects malformed content', () => {
    expect(validateOutgoing({ segments: [] })).toBe('message is empty');
    expect(validateOutgoing({ segments: [{ type: 'text', text: '' }] })).toBe('empty text segment');
    expect(validateOutgoing({ segments: [{ type: 'text', text: 'x'.repeat(5001) }] })).toMatch(/too long/);
    expect(validateOutgoing({ segments: [{ type: 'image', sha256: 'abc' }] })).toBe('invalid image sha256');
    expect(validateOutgoing({ segments: [{ type: 'file', sha256: SHA, name: '../etc/passwd' }] })).toBe('invalid file name');
    expect(validateOutgoing({ segments: [{ type: 'face', faceId: 'x' }] })).toBe('invalid face id');
    expect(validateOutgoing({ segments: [{ type: 'mention', userId: 0 }] })).toBe('invalid mention');
    expect(validateOutgoing({ segments: [{ type: 'text', text: 'hi' }], replyToSeq: -1 })).toBe('invalid reply seq');
  });
});
