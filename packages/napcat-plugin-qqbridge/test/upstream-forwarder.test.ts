import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { NapCatPluginContext } from '../src/napcat.js';
import { EventForwarder } from '../src/upstream/forwarder.js';
import { UpstreamQueue } from '../src/upstream/queue.js';

const logger = { log: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() };

let dir: string;
let queue: UpstreamQueue;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-fwd-'));
  queue = UpstreamQueue.open(dir);
});
afterEach(() => {
  queue.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

function ctxWith(call: (name: string, params: any) => Promise<unknown>): NapCatPluginContext {
  return {
    actions: { call: vi.fn((name: string, params: unknown) => call(name, params)) },
    adapterName: 'qqbridge',
    pluginManager: { config: {} },
  } as unknown as NapCatPluginContext;
}

const events = () => queue.read(0, 100).map((e) => e.e as Record<string, any>);

describe('EventForwarder', () => {
  it('queues everything except meta events and wakes the link', () => {
    const link = { notify: vi.fn() };
    const fwd = new EventForwarder(ctxWith(async () => null), queue, link, logger);
    fwd.onEvent({ post_type: 'meta_event', meta_event_type: 'heartbeat' });
    fwd.onEvent({ post_type: 'message', message_id: 1, raw: { msgSeq: '10' } });
    fwd.onEvent({ post_type: 'notice', notice_type: 'group_increase' });
    expect(events().map((e) => e.post_type)).toEqual(['message', 'notice']);
    expect(link.notify).toHaveBeenCalledTimes(2);
  });

  it('adds the real seq to recall notices, from recently seen messages or via get_msg', async () => {
    const getMsg = vi.fn(async (_name: string, params: any) => (params.message_id === 77 ? { real_seq: '9001' } : null));
    const fwd = new EventForwarder(ctxWith(getMsg), queue, null, logger);
    fwd.onEvent({
      post_type: 'message',
      message_type: 'group',
      message_id: 5,
      raw: { msgSeq: '321', msgId: '7300000000000000001', chatType: 2, peerUin: '123456', peerUid: '123456' },
    });
    fwd.onEvent({ post_type: 'notice', notice_type: 'group_recall', group_id: 123456, message_id: 5 }); // 见过
    fwd.onEvent({ post_type: 'notice', notice_type: 'friend_recall', user_id: 42, message_id: 77 }); // 没见过 → get_msg
    fwd.onEvent({ post_type: 'notice', notice_type: 'friend_recall', user_id: 42, message_id: 78 }); // 查不到也照样转发
    await vi.waitFor(() => expect(events()).toHaveLength(4));

    const recalls = events().filter((e) => e.post_type === 'notice');
    expect(recalls.find((e) => e.message_id === 5)?.qqbridge).toEqual({
      message: { msgSeq: '321', msgId: '7300000000000000001', chatType: 2, peerUin: '123456', peerUid: '123456' },
    });
    expect(recalls.find((e) => e.message_id === 77)?.qqbridge).toEqual({ message: { msgSeq: '9001' } });
    expect(recalls.find((e) => e.message_id === 78)?.qqbridge).toBeUndefined();
    expect(getMsg).toHaveBeenCalledTimes(2); // 见过的那条没有再调 get_msg
  });

  it('also resolves the message behind essence and emoji-like notices', async () => {
    const fwd = new EventForwarder(ctxWith(async () => null), queue, null, logger);
    fwd.onEvent({ post_type: 'message', message_type: 'group', message_id: 9, raw: { msgSeq: '500', chatType: 2, peerUin: '1' } });
    fwd.onEvent({ post_type: 'notice', notice_type: 'essence', sub_type: 'add', group_id: 1, message_id: 9 });
    fwd.onEvent({ post_type: 'notice', notice_type: 'group_msg_emoji_like', group_id: 1, message_id: 9, likes: [] });
    await vi.waitFor(() => expect(events()).toHaveLength(3));
    for (const e of events().filter((e) => e.post_type === 'notice')) expect(e.qqbridge?.message?.msgSeq).toBe('500');
  });
});
