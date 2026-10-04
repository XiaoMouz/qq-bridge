import { describe, expect, it } from 'vitest';
import { applyReactionChange } from '../src/events.ts';

describe('applyReactionChange', () => {
  it('updates counts, tracks my own reaction, appends new emojis and drops zero counts', () => {
    let r = applyReactionChange([], { likes: [{ emojiId: '76', count: 1 }], byMe: false, isAdd: true });
    expect(r).toEqual([{ emojiId: '76', count: 1 }]);
    r = applyReactionChange(r, { likes: [{ emojiId: '76', count: 2 }], byMe: true, isAdd: true });
    expect(r).toEqual([{ emojiId: '76', count: 2, me: true }]);
    r = applyReactionChange(r, { likes: [{ emojiId: '66', count: 1 }], byMe: false, isAdd: true });
    expect(r.map((x) => x.emojiId)).toEqual(['76', '66']);
    r = applyReactionChange(r, { likes: [{ emojiId: '76', count: 1 }], byMe: true, isAdd: false });
    expect(r).toEqual([{ emojiId: '76', count: 1 }, { emojiId: '66', count: 1 }]);
    r = applyReactionChange(r, { likes: [{ emojiId: '66', count: 0 }], byMe: false, isAdd: false });
    expect(r).toEqual([{ emojiId: '76', count: 1 }]);
  });
});
