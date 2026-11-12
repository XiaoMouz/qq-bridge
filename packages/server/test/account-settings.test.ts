// 账号设置（「通知手机」）：改动占 pts，在线设备经 Subscribe 马上收到，离线设备补差量时拿到。
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { setAccountSettings } from '../src/auth/settings.ts';
import { PhoneAutoMute } from '../src/push/phone-auto-mute.ts';
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
    expect(res).toEqual({
      pts: before + 1,
      settings: { phoneNotificationsOff: true, phoneAutoOff: false },
      previous: { phoneNotificationsOff: false, phoneAutoOff: false },
    });

    expect((await getDifference(t.db, acc.accountId, 0)).settings).toEqual({ phoneNotificationsOff: true, phoneAutoOff: false });
    expect((await getDifference(t.db, acc.accountId, before)).settings).toEqual({ phoneNotificationsOff: true, phoneAutoOff: false });
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
    expect(live).toEqual([{ kind: 'update', update: { type: 'settings', pts: res.pts, settings: { phoneNotificationsOff: true, phoneAutoOff: false } } }]);
  });
});

describe('在线时自动停用通知到手机', () => {
  it('报到后自动停用，租约过期恢复；没变化不占 pts', async () => {
    const svc = services(t.db);
    const acc = await createTestAccount(t.db, svc.ingest);
    let now = 1_000_000;
    const mute = new PhoneAutoMute(t.db, svc.writers, { now: () => now, leaseMs: 75_000 });
    const start = (await getState(t.db, acc.accountId)).pts;

    await mute.report(acc.accountId, 10, true);
    expect((await getDifference(t.db, acc.accountId, start)).settings).toEqual({ phoneNotificationsOff: false, phoneAutoOff: true });
    const afterOn = (await getState(t.db, acc.accountId)).pts;
    expect(afterOn).toBe(start + 1);

    // 续租：状态没变，不分配 pts。
    now += 30_000;
    await mute.report(acc.accountId, 10, true);
    expect((await getState(t.db, acc.accountId)).pts).toBe(afterOn);

    // 还没过期。
    now += 60_000;
    await mute.expire();
    expect((await getDifference(t.db, acc.accountId, start)).settings?.phoneAutoOff).toBe(true);

    // 最后一次续租后 75 秒没报到：当作下线。
    now += 20_000;
    await mute.expire();
    expect((await getDifference(t.db, acc.accountId, afterOn)).settings).toEqual({ phoneNotificationsOff: false, phoneAutoOff: false });
  });

  it('手机上点「打开」：这次在线期间不再停用；下线再上线重新生效', async () => {
    const svc = services(t.db);
    const acc = await createTestAccount(t.db, svc.ingest);
    const mute = new PhoneAutoMute(t.db, svc.writers);
    const autoOff = async () => (await getDifference(t.db, acc.accountId, 0)).settings?.phoneAutoOff;

    await mute.report(acc.accountId, 10, true);
    expect(await autoOff()).toBe(true);
    await mute.override(acc.accountId);
    expect(await autoOff()).toBe(false);
    await mute.report(acc.accountId, 10, true);
    expect(await autoOff()).toBe(false);

    // 另一台设备上线：它没被解除，照常停用。
    await mute.report(acc.accountId, 11, true);
    expect(await autoOff()).toBe(true);
    await mute.report(acc.accountId, 11, false);
    expect(await autoOff()).toBe(false);

    // 被解除的设备下线后再上线：重新停用。
    await mute.report(acc.accountId, 10, false);
    await mute.report(acc.accountId, 10, true);
    expect(await autoOff()).toBe(true);
  });

  it('启动时清掉上次留下的自动停用', async () => {
    const svc = services(t.db);
    const acc = await createTestAccount(t.db, svc.ingest);
    await new PhoneAutoMute(t.db, svc.writers).report(acc.accountId, 10, true);
    const fresh = new PhoneAutoMute(t.db, svc.writers);
    await fresh.start(60_000);
    fresh.stop();
    expect((await getDifference(t.db, acc.accountId, 0)).settings?.phoneAutoOff).toBe(false);
  });
});
