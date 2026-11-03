import { describe, expect, it, vi } from 'vitest';
import type { NapCatPluginContext } from '../src/napcat.js';
import { createHandlers } from '../src/upstream/handlers.js';

const ctx = { actions: { call: vi.fn() }, core: {} } as unknown as NapCatPluginContext;

describe('file download URLs', () => {
  it.each([1, 100])('uses the logged-in receiver for private chat type %i', async (chatType) => {
    const getFileUrl = vi.fn(async (_type: number, uid: string) => {
      if (uid !== 'u_self') throw new Error('0xE37_1200 timeout');
      return 'https://example.com/file';
    });
    const context = {
      ...ctx,
      core: { selfInfo: { uid: 'u_self', uin: '10001' }, apis: { FileApi: { getFileUrl } } },
    };
    const result = await createHandlers(context)['x.media_url']!({
      chatType, peerUid: 'u_friend', msgId: 'message', elementId: 'element', elementType: 3,
      fileUuid: 'private-file', file10MMd5: 'md5',
    });
    expect(result).toEqual({ url: 'https://example.com/file' });
    expect(getFileUrl).toHaveBeenCalledWith(chatType, 'u_self', 'private-file', 'md5', 5000);
  });

  it('keeps the group number when requesting a group file', async () => {
    const getFileUrl = vi.fn(async () => 'https://example.com/group-file');
    const context = { ...ctx, core: { apis: { FileApi: { getFileUrl } } } };
    await createHandlers(context)['x.media_url']!({
      chatType: 2, peerUid: '521409608', elementType: 3, fileUuid: 'group-file', file10MMd5: 'md5',
    });
    expect(getFileUrl).toHaveBeenCalledWith(2, '521409608', 'group-file', 'md5', 5000);
  });

  it('does not substitute the peer when the logged-in identity is unavailable', async () => {
    const getFileUrl = vi.fn();
    const context = { ...ctx, core: { apis: { FileApi: { getFileUrl } } } };
    await expect(createHandlers(context)['x.media_url']!({
      chatType: 1, peerUid: 'u_friend', elementType: 3, fileUuid: 'private-file',
    })).rejects.toThrow('QQ self identity is not available yet');
    expect(getFileUrl).not.toHaveBeenCalled();
  });
});

describe('call RPCs', () => {
  it('answer through the call bridge when it is on', async () => {
    const calls = { current: vi.fn(() => ({ phase: 'ringing' })), accept: vi.fn(async () => ({ phase: 'accepting' })), hangup: vi.fn(async () => ({ phase: 'ended' })), startCall: vi.fn(async () => ({ phase: 'ringing' })), status: vi.fn(() => ({ loginPosted: true, serviceMethods: ['x'] })) };
    const handlers = createHandlers(ctx, { calls });
    expect(await handlers['x.call.current']!({})).toEqual({ phase: 'ringing' });
    expect(await handlers['x.call.accept']!({})).toEqual({ phase: 'accepting' });
    expect(calls.accept).toHaveBeenCalledTimes(1);
    expect(await handlers['x.call.hangup']!({})).toEqual({ phase: 'ended' });
    expect(await handlers['x.call.status']!({})).toEqual({ enabled: true, loginPosted: true });
  });

  it('report that calls are off instead of failing silently', async () => {
    const handlers = createHandlers(ctx, { calls: null });
    await expect(handlers['x.call.accept']!({})).rejects.toThrow(/call bridge is off/);
    expect(await handlers['x.call.status']!({})).toEqual({ enabled: false });
  });
});
