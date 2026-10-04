import { describe, expect, it } from 'vitest';
import { buildAcceptParams } from '../src/call/accept-params.js';

describe('buildAcceptParams', () => {
  it('uses the inviter (invite[1]) as the native session key', () => {
    const invite = [1, 'inviter-uid', 'self-uid', 2, 'room-key', null, null, null, null, null, 1, 'extra'];
    expect(buildAcceptParams(invite)).toEqual([1, 'inviter-uid', ['inviter-uid'], 2, 'room-key', true, 'extra']);
  });

  it('rejects incomplete invites before touching AVSDK', () => {
    expect(() => buildAcceptParams([1, 'uid'])).toThrow(/incomplete/);
    expect(() => buildAcceptParams(Array(12).fill(null))).toThrow(/native Accept signature/);
    expect(() => buildAcceptParams('not-an-array')).toThrow(/incomplete/);
  });
});
