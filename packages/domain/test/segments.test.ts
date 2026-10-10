import { describe, expect, it } from 'vitest';
import { MessageFlag, messageFlags, plainText, updateMediaInfo, markdownText } from '../src/segments.ts';
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

describe('markdownText', () => {
  it('turns bot markdown into a readable preview', () => {
    const md = '[@短歌今难长](mqqapi://markdown/mention?at_type=1)\n\n# ✅ 签到成功\n\n**今日幸运值：54** · 中吉\n![DT 30PM #300px #200px](https://qqbot.ugcimg.cn/1.png)\n[【远行商人】](mqqapi://aio/inlinecmd?command=%2F)';
    expect(markdownText(md)).toBe('@短歌今难长\n\n✅ 签到成功\n\n今日幸运值：54 · 中吉\n[图片]\n【远行商人】');
    expect(plainText([{ type: 'markdown', content: md }])).toBe(markdownText(md));
  });
});
