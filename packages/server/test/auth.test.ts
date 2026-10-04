import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AuthService, hashToken, InvalidCredentialsError } from '../src/auth/service.ts';
import { maybeOne } from '../src/db/client.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

describe('AuthService', () => {
  it('logs in per device, stores only the token hash, and supports revocation', async () => {
    const auth = new AuthService(t.db);
    const accountId = await auth.createAccount('owner', 'correct horse battery');
    const phone = await auth.login('owner', 'correct horse battery', { name: 'iPhone', platform: 'ios' });
    const ipad = await auth.login('owner', 'correct horse battery', { name: 'iPad', platform: 'ios' });
    expect(phone.accountId).toBe(accountId);
    expect(phone.token).toMatch(/^qqb_[A-Za-z0-9_-]{43}$/);

    const stored = await maybeOne<{ token_hash: Buffer }>(t.db, sql`select token_hash from devices where id = ${phone.deviceId}`);
    expect(stored?.token_hash.equals(hashToken(phone.token))).toBe(true);

    expect(await auth.authenticate(phone.token)).toEqual({ accountId, deviceId: phone.deviceId });
    expect(await auth.authenticate('qqb_forged')).toBeNull();

    const devices = await auth.listDevices({ accountId, deviceId: phone.deviceId });
    expect(devices.map((d) => [d.name, d.current])).toEqual([
      ['iPhone', true],
      ['iPad', false],
    ]);

    expect(await auth.revokeDevice({ accountId, deviceId: phone.deviceId }, ipad.deviceId)).toBe(true);
    expect(await auth.authenticate(ipad.token)).toBeNull();
    expect(await auth.authenticate(phone.token)).not.toBeNull();
  });

  it('rejects wrong passwords and unknown users the same way', async () => {
    const auth = new AuthService(t.db);
    await auth.createAccount('someone', 'another long password');
    await expect(auth.login('someone', 'nope-nope', { name: 'x', platform: 'ios' })).rejects.toBeInstanceOf(InvalidCredentialsError);
    await expect(auth.login('nobody', 'whatever!!', { name: 'x', platform: 'ios' })).rejects.toBeInstanceOf(InvalidCredentialsError);
  });
});
