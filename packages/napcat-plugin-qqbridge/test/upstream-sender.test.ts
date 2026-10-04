import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ActionResult, NapCatPluginContext } from '../src/napcat.js';
import { callAction } from '../src/upstream/actions.js';
import { Sender } from '../src/upstream/sender.js';

const logger = { log: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() };
let dir: string;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-sender-'));
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

/** 模拟 NapCat 的 actions：handle 返回完整的 OB11Return。 */
function fakeCtx(handlers: Record<string, (params: any) => Promise<ActionResult>>) {
  const calls: { name: string; params: any }[] = [];
  const ctx = {
    adapterName: 'qqbridge',
    pluginManager: { config: {} },
    actions: {
      call: vi.fn(),
      get: (name: string) =>
        handlers[name]
          ? {
              handle: async (params: unknown) => {
                calls.push({ name, params });
                return handlers[name]!(params);
              },
            }
          : undefined,
    },
  } as unknown as NapCatPluginContext;
  return { ctx, calls };
}

const ok = (data: unknown): ActionResult => ({ status: 'ok', retcode: 0, data });

describe('Sender (x.send)', () => {
  it('sends once per clientRandomId, even across concurrent retries and plugin restarts', async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    const { ctx, calls } = fakeCtx({
      send_group_msg: async () => {
        await gate;
        return ok({ message_id: 501 });
      },
    });
    const keys = { lookup: (id: number) => (id === 501 ? { msgSeq: '9001', msgId: '7400000000000000501' } : undefined) };
    const sender = new Sender(ctx, keys, dir, logger);
    const params = { clientRandomId: '42', chatType: 2, peerUin: '123456', message: [{ type: 'text', data: { text: 'hi' } }] };

    const first = sender.send(params);
    const retryWhileRunning = sender.send(params); // 服务端超时后重试：共用同一个结果
    release();
    expect(await first).toEqual({ messageId: 501, msgSeq: '9001', msgId: '7400000000000000501' });
    expect(await retryWhileRunning).toEqual(await first);
    expect(await sender.send(params)).toEqual(await first); // 发完后再重试
    expect(calls.filter((c) => c.name === 'send_group_msg')).toHaveLength(1);
    expect(calls[0]!.params).toEqual({ group_id: 123456, message: params.message });

    // 插件重启：从磁盘恢复已发送记录。
    const restarted = new Sender(ctx, { lookup: () => undefined }, dir, logger);
    expect(await restarted.send(params)).toEqual(await first);
    expect(calls.filter((c) => c.name === 'send_group_msg')).toHaveLength(1);
  });

  it('resolves the seq via get_msg when the sent event has not been seen, and lets failed sends be retried', async () => {
    let fail = true;
    const { ctx, calls } = fakeCtx({
      send_private_msg: async () => (fail ? { status: 'failed', retcode: 1200, data: null, message: '对方不是你的好友' } : ok({ message_id: 7 })),
      get_msg: async () => ok({ real_seq: '33' }),
    });
    const sender = new Sender(ctx, { lookup: () => undefined }, dir, logger);
    const params = { clientRandomId: '43', chatType: 1, peerUin: '30003', message: [{ type: 'text', data: { text: 'x' } }] };
    await expect(sender.send(params)).rejects.toThrow('对方不是你的好友');
    fail = false;
    expect(await sender.send(params)).toEqual({ messageId: 7, msgSeq: '33' });
    expect(calls.map((c) => c.name)).toEqual(['send_private_msg', 'send_private_msg', 'get_msg']);
    expect(calls[0]!.params).toMatchObject({ user_id: 30003 });
  });

  it('rejects malformed requests without calling QQ', async () => {
    const { ctx, calls } = fakeCtx({});
    const sender = new Sender(ctx, { lookup: () => undefined }, dir, logger);
    await expect(sender.send({ clientRandomId: '', chatType: 2, peerUin: '1', message: [{}] })).rejects.toThrow('clientRandomId');
    await expect(sender.send({ clientRandomId: '1', chatType: 2, peerUin: '1', message: [] })).rejects.toThrow('empty');
    await expect(sender.send({ clientRandomId: '2', chatType: 2, peerUin: 'abc', message: [{}] })).rejects.toThrow('invalid peer');
    expect(calls).toEqual([]);
  });
});

describe('callAction', () => {
  it('treats "ok without data" as success and surfaces QQ error messages', async () => {
    const { ctx } = fakeCtx({
      mark_group_msg_as_read: async () => ok(null),
      delete_msg: async () => ({ status: 'failed', retcode: 200, data: null, message: '超过撤回时限' }),
    });
    expect(await callAction(ctx, 'mark_group_msg_as_read', { group_id: 1 })).toBeNull();
    await expect(callAction(ctx, 'delete_msg', {})).rejects.toThrow('超过撤回时限');
  });
});
