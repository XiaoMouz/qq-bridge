// 账号设置（「通知手机」）：改动占 pts，在线设备经 Subscribe 马上收到，离线设备补差量时拿到。
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { setAccountSettings } from '../src/auth/settings.ts';
import { getDifference, getState } from '../src/sync/difference.ts';
import { subscribe, type StreamEvent } from '../src/sync/subscribe.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('账号设置同步', () => {
  it('没改过时差量里不带设置；改了之后差量带上最新值，旧游标之后才有', async () => {
    const svc = services(t.db);
    const acc = await createTestAccount(t.db, svc.ingest);
    expect((await getDifference(t.db, acc.accountId, 0)).settings).toBeNull();

    const before = (await getState(t.db, acc.accountId)).pts;
    const res = await setAccountSettings(svc.writers, acc.accountId, { phoneNotificationsOff: true });
    expect(res).toEqual({ pts: before + 1, settings: { phoneNotificationsOff: true } });

    expect((await getDifference(t.db, acc.accountId, 0)).settings).toEqual({ phoneNotificationsOff: true });
    expect((await getDifference(t.db, acc.accountId, before)).settings).toEqual({ phoneNotificationsOff: true });
    expect((await getDifference(t.db, acc.accountId, res.pts)).settings).toBeNull();
  });

  it('在线设备经 Subscribe 收到 settings 更新', async () => {
    const svc = services(t.db);
    const acc = await createTestAccount(t.db, svc.ingest);
    const controller = new AbortController();
    const events: StreamEvent[] = [];
    const consumer = (async () => {
      for await (const event of subscribe(t.db, svc.bus, acc.accountId, 0, controller.signal, { heartbeatMs: 50 })) {
        events.push(event);
        if (event.kind === 'update' && event.update.type === 'settings') controller.abort();
      }
    })();
    await new Promise((resolve) => setTimeout(resolve, 50));
    const res = await setAccountSettings(svc.writers, acc.accountId, { phoneNotificationsOff: true });
    await consumer;
    const live = events.filter((e) => e.kind === 'update');
    expect(live).toEqual([{ kind: 'update', update: { type: 'settings', pts: res.pts, settings: { phoneNotificationsOff: true } } }]);
  });
});
