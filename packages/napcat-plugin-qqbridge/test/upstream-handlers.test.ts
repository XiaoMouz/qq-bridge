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
      chatType: 2, peerUid: '521409608', elementType: 3, fileUuid: '/group-file', file10MMd5: 'md5',
    });
    expect(getFileUrl).toHaveBeenCalledWith(2, '521409608', '/group-file', 'md5', 5000);
  });

  it('requests files kept inside a forward as private files of the logged-in account', async () => {
    // 2026-11-14 实测的聊天记录节点：原来的群、fileUuid 是「哈希_UUID」、没有 file10MMd5。
    const getFileUrl = vi.fn(async () => 'http://27.44.121.231:80/qqdownloadftnv5?ver=2&rkey=x');
    const context = { ...ctx, core: { selfInfo: { uid: 'u_self', uin: '10001' }, apis: { FileApi: { getFileUrl } } } };
    const result = await createHandlers(context)['x.media_url']!({
      chatType: 2, peerUid: '284840486', elementType: 3, fileUuid: '3f847d64_34783802-df5f', file10MMd5: '',
    });
    expect(result).toEqual({ url: 'http://27.44.121.231:80/qqdownloadftnv5?ver=2&rkey=x' });
    expect(getFileUrl).toHaveBeenCalledWith(1, 'u_self', '3f847d64_34783802-df5f', '0'.repeat(32), 5000);
  });

  it('treats group files QQ no longer serves (deleted, or a group we are not in) as gone', async () => {
    for (const message of ['sendGroupFileDownloadReq error: 文件不存在 (code=-103)', 'sendGroupFileDownloadReq error: 非群成员 (code=-102)']) {
      const getFileUrl = vi.fn(async () => { throw new Error(message); });
      const context = { ...ctx, core: { apis: { FileApi: { getFileUrl } } } };
      expect(await createHandlers(context)['x.media_url']!({ chatType: 2, peerUid: '284840486', elementType: 3, fileUuid: '/36d7dbbc' })).toEqual({ url: null });
    }
    const timeout = vi.fn(async () => { throw new Error('timeout'); });
    await expect(createHandlers({ ...ctx, core: { apis: { FileApi: { getFileUrl: timeout } } } })['x.media_url']!({
      chatType: 2, peerUid: '284840486', elementType: 3, fileUuid: '/36d7dbbc',
    })).rejects.toThrow('timeout');
  });

  it('treats a link without a host as no link', async () => {
    const getFileUrl = vi.fn(async () => 'http://undefined:undefinedundefined&isthumb=0');
    const context = { ...ctx, core: { selfInfo: { uid: 'u_self', uin: '10001' }, apis: { FileApi: { getFileUrl } } } };
    expect(await createHandlers(context)['x.media_url']!({ chatType: 2, peerUid: '1', elementType: 3, fileUuid: 'abc_def' })).toEqual({ url: null });
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
