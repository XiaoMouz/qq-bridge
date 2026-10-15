import { sql } from 'drizzle-orm';
import type { AuthContext } from '../auth/service.ts';
import { maybeOne } from '../db/client.ts';
import type { WriterRegistry } from '../sync/writer.ts';
import type { ApnsEnv } from './apns.ts';

export async function registerPush(
  writers: WriterRegistry,
  auth: AuthContext,
  input: { token: string; voipToken: string; env: ApnsEnv | null },
): Promise<void> {
  await writers.forAccount(auth.accountId).run(async ({ tx }) => {
    // 2026-10-15：同一 iPhone 重新登录生成记录 11，记录 5 仍持有相同令牌，
    // 导致逐记录推送两次。注册应转移端点归属，不能注销旧登录会话。
    // 行锁也让不同进程的注册串行，普通与 VoIP 分开回调不会互相覆盖。
    await tx.execute(sql`select id from accounts where id = ${auth.accountId} for update`);
    const current = await maybeOne<{ platform: string; apns_env: string | null }>(tx,
      sql`select platform, apns_env from devices
        where id = ${auth.deviceId} and account_id = ${auth.accountId} and revoked_at is null`);
    if (!current) return;
    const env = input.env ?? current.apns_env ?? 'production';
    const token = input.token.toLowerCase() || null;
    const voip = input.voipToken.toLowerCase() || null;
    const environmentChanged = (current.apns_env ?? 'production') !== env;
    await tx.execute(sql`update devices set
      apns_token = case when apns_token = ${token} then null else apns_token end,
      apns_voip_token = case when apns_voip_token = ${voip} then null else apns_voip_token end
      where account_id = ${auth.accountId} and id <> ${auth.deviceId}
        and (platform = 'macos') = ${current.platform === 'macos'}
        and coalesce(apns_env, 'production') = ${env}
        and (apns_token = ${token} or apns_voip_token = ${voip})`);
    await tx.execute(sql`update devices set
      apns_token = coalesce(${token}, case when ${environmentChanged} then null else apns_token end),
      apns_voip_token = coalesce(${voip}, case when ${environmentChanged} then null else apns_voip_token end),
      apns_env = ${env} where id = ${auth.deviceId}`);
  });
}
