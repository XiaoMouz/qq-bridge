import { describe, expect, it } from 'vitest';
import { MessageFlag, messageFlags, plainText, updateMediaInfo } from '../src/segments.ts';
import { classifyUpdate } from '../src/sync-rules.ts';
import type { Segment } from '../src/types.ts';

const SELF = 10001;

describe('segments', () => {
  const segments: Segment[] = [
    { type: 'reply', seq: 5 },
    { type: 'mention', userId: SELF, name: '我' },
    { type: 'text', text: ' 看看 https://example.com' },
    { type: 'image', media: { ord: 0, state: 'pending' } },
    { type: 'file', media: { ord: 1, state: 'pending' }, name: 'a.pdf' },
  ];

  it('derives flags for shared-media filters and mention badges', () => {
    const flags = messageFlags(segments, SELF);
    expect(flags & MessageFlag.mentionsMe).toBeTruthy();
    expect(flags & MessageFlag.link).toBeTruthy();
    expect(flags & MessageFlag.photo).toBeTruthy();
    expect(flags & MessageFlag.file).toBeTruthy();
    expect(flags & MessageFlag.video).toBe(0);
    expect(messageFlags([{ type: 'mention', userId: 1 }], SELF) & MessageFlag.mentionsMe).toBe(0);
  });

  it('renders searchable plain text with placeholders', () => {
    expect(plainText(segments)).toBe('@我 看看 https://example.com[图片][文件] a.pdf');
  });

  it('updates media info by ordinal without touching other segments', () => {
    const updated = updateMediaInfo(segments, 1, { state: 'stored', sha256: 'abc', size: 9 });
    expect(updated[4]).toEqual({ type: 'file', media: { ord: 1, state: 'stored', sha256: 'abc', size: 9 }, name: 'a.pdf' });
    expect(updated[3]).toBe(segments[3]);
  });
});

describe('classifyUpdate', () => {
  it('follows the Telegram pts rule', () => {
    expect(classifyUpdate(10, 11)).toBe('apply');
    expect(classifyUpdate(10, 10)).toBe('skip');
    expect(classifyUpdate(10, 13)).toBe('gap');
    expect(classifyUpdate(10, 12, 2)).toBe('apply');
  });
});
