import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { computeChatStorage, type ChatUsage } from '../src/storage.ts';

const usageArb: fc.Arbitrary<ChatUsage[]> = fc
  .array(
    fc.record({
      chatId: fc.integer({ min: 1, max: 5 }),
      blob: fc.integer({ min: 1, max: 8 }),
    }),
    { maxLength: 40 },
  )
  .map((items) => items.map(({ chatId, blob }) => ({ chatId, sha256: `b${blob}`, size: blob * 1000 })));

describe('computeChatStorage', () => {
  it('counts a blob shared by two chats as shared in both and exclusive in neither', () => {
    const result = computeChatStorage([
      { chatId: 1, sha256: 'a', size: 100 },
      { chatId: 2, sha256: 'a', size: 100 },
      { chatId: 1, sha256: 'b', size: 50 },
      { chatId: 1, sha256: 'b', size: 50 }, // 同一会话里出现两次，只算一次
    ]);
    expect(result.get(1)).toEqual({ logicalBytes: 150, exclusiveBytes: 50, blobCount: 2 });
    expect(result.get(2)).toEqual({ logicalBytes: 100, exclusiveBytes: 0, blobCount: 1 });
  });

  it('exclusive bytes across chats sum to the bytes of single-owner blobs', () => {
    fc.assert(
      fc.property(usageArb, (usages) => {
        const result = computeChatStorage(usages);
        const owners = new Map<string, Set<number>>();
        const sizes = new Map<string, number>();
        for (const u of usages) {
          sizes.set(u.sha256, u.size);
          owners.set(u.sha256, (owners.get(u.sha256) ?? new Set()).add(u.chatId));
        }
        const singleOwnerBytes = [...owners].filter(([, o]) => o.size === 1).reduce((s, [sha]) => s + sizes.get(sha)!, 0);
        const exclusiveSum = [...result.values()].reduce((s, r) => s + r.exclusiveBytes, 0);
        expect(exclusiveSum).toBe(singleOwnerBytes);
        for (const r of result.values()) expect(r.exclusiveBytes).toBeLessThanOrEqual(r.logicalBytes);
      }),
    );
  });
});
