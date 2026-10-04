// 通话管理：插件状态入库与推送、接听顺序（网关先入会再让 QQ 接听）、结束后留通话记录、过期振铃、经收件箱接入。
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { CallService, type PluginCallState } from '../src/calls/service.ts';
import { rows } from '../src/db/client.ts';
import { InboxProcessor } from '../src/upstream/inbox.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

const LIVEKIT = { livekitApiKey: 'key', livekitApiSecret: 's'.repeat(32), livekitPublicUrl: 'wss://mac.example.ts.net:7443' };

function state(over: Partial<PluginCallState> = {}): PluginCallState {
  return {
    callId: 'c-1',
    phase: 'ringing',
    inviteAt: new Date().toISOString(),
    acceptedAt: null,
    connectedAt: null,
    endedAt: null,
    endReason: null,
    inviteType: 1,
    callerUid: 'u_x',
    callerUin: '2635832018',
    callerName: '测试来电',
    ...over,
  };
}

function setup() {
  const steps: string[] = [];
  const gateway = {
    join: async (room: string) => void steps.push(`gateway join ${room}`),
    leave: async (room: string) => void steps.push(`gateway leave ${room}`),
  };
  const hub = {
    call: async <T,>(_qq: number, action: string): Promise<T> => {
      steps.push(`plugin ${action}`);
      return {} as T;
    },
  };
  return { steps, gateway, hub };
}

describe('CallService', () => {
  it('answers by putting the gateway in the room first, then records the call in the chat when it ends', async () => {
    const { ingest, bus } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const { steps, gateway, hub } = setup();
    const calls = new CallService(t.db, ingest, hub, gateway, LIVEKIT);
    const pushed: string[] = [];
    bus.subscribe(acc.accountId, (u) => {
      if (u.type === 'call') pushed.push(u.call.phase);
    });

    const callId = `c-${acc.uin}`;
    const inviteAt = new Date(Date.now() - 30_000).toISOString();
    expect(await calls.onPluginState(acc.qqAccountId, state({ callId, inviteAt, callerName: null }))).toBe(true);
    await calls.onPluginState(acc.qqAccountId, state({ callId, inviteAt })); // 来电者昵称晚到
    expect(await calls.active(acc.accountId)).toMatchObject({ callId, phase: 'ringing', peerUin: 2635832018, peerName: '测试来电' });

    const answered = await calls.answer(acc.accountId, 77, callId);
    expect(steps).toEqual([`gateway join qq-call-${callId}`, 'plugin x.call.accept']);
    expect(answered).toMatchObject({ url: LIVEKIT.livekitPublicUrl, room: `qq-call-${callId}` });
    expect(answered.token.split('.')).toHaveLength(3); // JWT
    expect(answered.call.answeredDeviceId).toBe(77);

    const connectedAt = new Date(Date.now() - 20_000).toISOString();
    await calls.onPluginState(acc.qqAccountId, state({ callId, inviteAt, phase: 'connected', connectedAt }));
    await calls.onPluginState(acc.qqAccountId, state({ callId, inviteAt, phase: 'ended', connectedAt, endedAt: new Date().toISOString(), endReason: 1 }));
    await calls.onPluginState(acc.qqAccountId, state({ callId, inviteAt, phase: 'connected', connectedAt })); // 乱序重放：不会复活
    expect(await calls.active(acc.accountId)).toBeNull();
    expect(steps.at(-1)).toBe(`gateway leave qq-call-${callId}`);
    expect(pushed).toContain('ringing');
    expect(pushed.at(-1)).toBe('ended');

    const events = await rows<{ kind: string; data: Record<string, unknown> }>(
      t.db,
      sql`select e.kind, e.data from chat_events e join chats c on c.id = e.chat_id
           where c.qq_account_id = ${acc.qqAccountId} and c.peer_id = 2635832018`,
    );
    expect(events).toHaveLength(1); // 重放没有再记一次
    expect(events[0]).toMatchObject({ kind: 'call', data: { result: 'answered', incoming: true, media: 'voice', answeredHere: true } });
    expect(events[0]!.data.durationSec).toBeGreaterThanOrEqual(19);
  });

  it('refuses to answer calls that are not ringing or belong to someone else, and expires stale rings', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const other = await createTestAccount(t.db, ingest);
    const { gateway, hub } = setup();
    const calls = new CallService(t.db, ingest, hub, gateway, LIVEKIT);

    const callId = `c2-${acc.uin}`;
    await calls.onPluginState(acc.qqAccountId, state({ callId }));
    await expect(calls.answer(other.accountId, 1, callId)).rejects.toMatchObject({ code: 'not_found' });

    // 服务端离线期间积压的旧来电：直接记成结束（未接）。
    const stale = `c3-${acc.uin}`;
    await calls.onPluginState(acc.qqAccountId, state({ callId: stale, inviteAt: new Date(Date.now() - 10 * 60_000).toISOString() }));
    expect(await calls.get(stale)).toMatchObject({ phase: 'ended' });
    await expect(calls.answer(acc.accountId, 1, stale)).rejects.toMatchObject({ code: 'not_ringing' });

    // 没配通话时可以记录，但不能接听。
    const bare = new CallService(t.db, ingest, null, null, null);
    await expect(bare.answer(acc.accountId, 1, callId)).rejects.toMatchObject({ code: 'unavailable' });
    expect(await bare.onPluginState(acc.qqAccountId, { ...state(), callId: null })).toBe(false);
  });

  it('receives call states from the plugin through the inbox', async () => {
    const { ingest } = services(t.db);
    const acc = await createTestAccount(t.db, ingest);
    const calls = new CallService(t.db, ingest, null, null, null);
    const inbox = new InboxProcessor(t.db, ingest, { onCall: (qq, s) => calls.onPluginState(qq, s) });
    const callId = `c4-${acc.uin}`;
    const outcome = await inbox.applyAction(acc.qqAccountId, { type: 'call', state: state({ callId }) });
    expect(outcome).toEqual({ state: 'done' });
    expect(await calls.get(callId)).toMatchObject({ phase: 'ringing' });
    const without = new InboxProcessor(t.db, ingest);
    expect(await without.applyAction(acc.qqAccountId, { type: 'call', state: state({ callId }) })).toMatchObject({ state: 'ignored' });
  });
});
