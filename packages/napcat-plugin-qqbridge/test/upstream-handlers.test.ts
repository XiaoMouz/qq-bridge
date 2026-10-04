import { describe, expect, it, vi } from 'vitest';
import type { NapCatPluginContext } from '../src/napcat.js';
import { createHandlers } from '../src/upstream/handlers.js';

const ctx = { actions: { call: vi.fn() }, core: {} } as unknown as NapCatPluginContext;

describe('call RPCs', () => {
  it('answer through the call bridge when it is on', async () => {
    const calls = { current: vi.fn(() => ({ phase: 'ringing' })), accept: vi.fn(async () => ({ phase: 'accepting' })), status: vi.fn(() => ({ loginPosted: true, serviceMethods: ['x'] })) };
    const handlers = createHandlers(ctx, { calls });
    expect(await handlers['x.call.current']!({})).toEqual({ phase: 'ringing' });
    expect(await handlers['x.call.accept']!({})).toEqual({ phase: 'accepting' });
    expect(calls.accept).toHaveBeenCalledTimes(1);
    expect(await handlers['x.call.status']!({})).toEqual({ enabled: true, loginPosted: true });
  });

  it('report that calls are off instead of failing silently', async () => {
    const handlers = createHandlers(ctx, { calls: null });
    await expect(handlers['x.call.accept']!({})).rejects.toThrow(/call bridge is off/);
    expect(await handlers['x.call.status']!({})).toEqual({ enabled: false });
  });
});
