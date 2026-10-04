import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { originalPurgeable, refKeepsOriginal, resolveRule, type PolicyRecord, type RefRetention } from '../src/retention.ts';

const DAY = 86_400;
const NOW = 1_800_000_000;

const ruleArb = fc.record({
  keepOriginalDays: fc.option(fc.integer({ min: 0, max: 400 }), { nil: null }),
});
const refArb: fc.Arbitrary<RefRetention> = fc.record({
  time: fc.integer({ min: NOW - 800 * DAY, max: NOW }),
  override: fc.option(fc.boolean(), { nil: null }),
  rule: ruleArb,
});

describe('resolveRule', () => {
  const policies: PolicyRecord[] = [
    { scope: 'global', rule: { keepOriginalDays: 365 } },
    { scope: 'scene', scene: 'group', rule: { keepOriginalDays: 30 } },
    { scope: 'chat', chatId: 7, rule: { keepOriginalDays: null } },
  ];

  it('prefers chat over scene over global', () => {
    expect(resolveRule(policies, { chatId: 7, scene: 'group' })).toEqual({ keepOriginalDays: null });
    expect(resolveRule(policies, { chatId: 8, scene: 'group' })).toEqual({ keepOriginalDays: 30 });
    expect(resolveRule(policies, { chatId: 9, scene: 'friend' })).toEqual({ keepOriginalDays: 365 });
  });

  it('defaults to keeping originals forever', () => {
    expect(resolveRule([], { chatId: 1, scene: 'friend' })).toEqual({ keepOriginalDays: null });
  });
});

describe('original retention', () => {
  it('respects day boundaries and overrides', () => {
    const rule = { keepOriginalDays: 30 };
    expect(refKeepsOriginal({ time: NOW - 29 * DAY, override: null, rule }, NOW)).toBe(true);
    expect(refKeepsOriginal({ time: NOW - 30 * DAY, override: null, rule }, NOW)).toBe(false);
    expect(refKeepsOriginal({ time: NOW, override: null, rule: { keepOriginalDays: 0 } }, NOW)).toBe(false);
    expect(refKeepsOriginal({ time: NOW - 5000 * DAY, override: null, rule: { keepOriginalDays: null } }, NOW)).toBe(true);
    expect(refKeepsOriginal({ time: NOW, override: false, rule: { keepOriginalDays: null } }, NOW)).toBe(false);
  });

  it('never purges an original that any reference still needs (strongest retention wins)', () => {
    fc.assert(
      fc.property(fc.array(refArb, { minLength: 1, maxLength: 8 }), (refs) => {
        const purgeable = originalPurgeable(refs, NOW);
        const anyNeeds = refs.some((r) => refKeepsOriginal(r, NOW));
        expect(purgeable).toBe(!anyNeeds);
      }),
    );
  });

  it('adding a forever-retaining reference always protects the original', () => {
    fc.assert(
      fc.property(fc.array(refArb, { maxLength: 8 }), (refs) => {
        const keeper: RefRetention = { time: NOW, override: null, rule: { keepOriginalDays: null } };
        expect(originalPurgeable([...refs, keeper], NOW)).toBe(false);
      }),
    );
  });
});
